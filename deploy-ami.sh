#!/bin/bash
# One-command Tyn deploy: source -> running AWS instance serving HTTP.
# Builds the kernel, makes a BIOS disk image, imports it as an EBS snapshot,
# registers an AMI, and launches an instance. Run from the repo root on a
# build host with the toolchain + AWS access (see directions/PRODUCTION_READY.md).
set -euo pipefail

# --- Provenance gate: every deployed artifact must trace to a git commit. ---
# The build host is a real clone (see docs/PAYDOWN.md — the non-git-build-host
# blocker). Refuse to build from a dirty tree (that's how an untracked beam or a
# hand-edit silently ships), and record the built HEAD SHA so the deploy log ties
# the artifact to a commit. Override for a deliberate experiment with
# PROVENANCE_ALLOW_DIRTY=1 (it still logs, loudly).
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    BUILD_SHA=$(git rev-parse HEAD)
    BUILD_DIRTY=$(git status --porcelain)
    BEAM_SHA=$(sha256sum src/beam.smp.elf 2>/dev/null | cut -c1-16)
    echo "=== Provenance ===  HEAD=$BUILD_SHA  beam=$BEAM_SHA  tree=$([ -z "$BUILD_DIRTY" ] && echo clean || echo DIRTY)"
    if [ -n "$BUILD_DIRTY" ]; then
        echo "$BUILD_DIRTY" | sed 's/^/    /'
        if [ "${PROVENANCE_ALLOW_DIRTY:-0}" != "1" ]; then
            echo "ERROR: refusing to deploy from a dirty tree (artifact would not trace to a commit)." >&2
            echo "       commit the change, or set PROVENANCE_ALLOW_DIRTY=1 to override." >&2
            exit 1
        fi
        echo "WARNING: PROVENANCE_ALLOW_DIRTY=1 — deploying an untracked tree state."
    fi
else
    echo "WARNING: not a git repo — cannot record build provenance (see docs/PAYDOWN.md)."
fi

REGION="${AWS_REGION:-us-east-1}"
BUCKET="tyn-images-$(aws sts get-caller-identity --query Account --output text)"
INSTANCE_TYPE="${INSTANCE_TYPE:-c5.large}"
SG_NAME="${SG_NAME:-tyn-sg}"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
DISK_IMAGE="/dev/shm/tyn-disk.raw"

echo "=== Tyn AMI Deploy ===  region=$REGION  type=$INSTANCE_TYPE  bucket=$BUCKET"

echo "--- Building kernel ---"
cargo build --release --target x86_64-tyn.json \
    -Zbuild-std=core,alloc,compiler_builtins \
    -Zbuild-std-features=compiler-builtins-mem

echo "--- Building disk image ---"
./build-disk.sh
ls -lh "$DISK_IMAGE"

echo "--- Uploading to S3 ---"
S3_KEY="tyn-disk-${TIMESTAMP}.raw"
aws s3 cp "$DISK_IMAGE" "s3://${BUCKET}/${S3_KEY}" --region "$REGION"

echo "--- Importing EBS snapshot (5-10 min) ---"
IMPORT_TASK=$(aws ec2 import-snapshot --region "$REGION" \
    --description "Tyn ${TIMESTAMP}" \
    --disk-container "Format=RAW,UserBucket={S3Bucket=${BUCKET},S3Key=${S3_KEY}}" \
    --query 'ImportTaskId' --output text)
echo "Import task: $IMPORT_TASK"
while true; do
    STATUS=$(aws ec2 describe-import-snapshot-tasks --region "$REGION" \
        --import-task-ids "$IMPORT_TASK" \
        --query 'ImportSnapshotTasks[0].SnapshotTaskDetail.Status' --output text 2>/dev/null || echo pending)
    PROGRESS=$(aws ec2 describe-import-snapshot-tasks --region "$REGION" \
        --import-task-ids "$IMPORT_TASK" \
        --query 'ImportSnapshotTasks[0].SnapshotTaskDetail.Progress' --output text 2>/dev/null || echo "?")
    echo "  status=$STATUS ($PROGRESS%)"
    [ "$STATUS" = "completed" ] && break
    if [ "$STATUS" = "error" ] || [ "$STATUS" = "deleted" ]; then echo "ERROR: import failed"; exit 1; fi
    sleep 15
done
SNAPSHOT_ID=$(aws ec2 describe-import-snapshot-tasks --region "$REGION" \
    --import-task-ids "$IMPORT_TASK" \
    --query 'ImportSnapshotTasks[0].SnapshotTaskDetail.SnapshotId' --output text)
echo "Snapshot: $SNAPSHOT_ID"

echo "--- Registering AMI ---"
# NOTE: --boot-mode legacy-bios is REQUIRED — Tyn boots via GRUB/multiboot1
# (BIOS), not UEFI. DeleteOnTermination keeps stray snapshots from piling up.
AMI_ID=$(aws ec2 register-image --region "$REGION" \
    --name "tyn-${TIMESTAMP}" \
    --description "Tyn BEAM unikernel - OTP 27, JIT, Phoenix" \
    --architecture x86_64 --root-device-name /dev/xvda \
    --block-device-mappings "DeviceName=/dev/xvda,Ebs={SnapshotId=${SNAPSHOT_ID},VolumeSize=1,DeleteOnTermination=true,VolumeType=gp3}" \
    --virtualization-type hvm --boot-mode legacy-bios --ena-support \
    --query 'ImageId' --output text)
echo "AMI: $AMI_ID"

echo "--- Security group ---"
# Caller may pass SG_ID=sg-xxxx to reuse an existing group; otherwise we
# find or create one named $SG_NAME with ports 8080 + 9090 open.
if [ -z "${SG_ID:-}" ]; then
    SG_ID=$(aws ec2 describe-security-groups --region "$REGION" \
        --filters "Name=group-name,Values=${SG_NAME}" \
        --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo None)
    if [ "$SG_ID" = "None" ] || [ -z "$SG_ID" ]; then
        SG_ID=$(aws ec2 create-security-group --region "$REGION" \
            --group-name "$SG_NAME" --description "Tyn unikernel" \
            --query 'GroupId' --output text)
        aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_ID" --protocol tcp --port 8080 --cidr 0.0.0.0/0
        aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SG_ID" --protocol tcp --port 9090 --cidr 0.0.0.0/0
        echo "Created $SG_ID ($SG_NAME; 8080, 9090 open)"
    else
        echo "Using existing $SG_NAME = $SG_ID"
    fi
else
    echo "Using caller-provided SG_ID = $SG_ID"
fi

echo "--- Launching ---"
INSTANCE_ID=$(aws ec2 run-instances --region "$REGION" \
    --image-id "$AMI_ID" --instance-type "$INSTANCE_TYPE" \
    --security-group-ids "$SG_ID" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=tyn-${TIMESTAMP}}]" \
    --query 'Instances[0].InstanceId' --output text)
aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"
PUBLIC_IP=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

cat <<MSG

=== Tyn deployed ===
Instance:  $INSTANCE_ID
AMI:       $AMI_ID
Snapshot:  $SNAPSHOT_ID
Public IP: $PUBLIC_IP

Wait ~15s for boot + DHCP, then:
  curl http://${PUBLIC_IP}:8080/
  curl http://${PUBLIC_IP}:8080/health
  curl http://${PUBLIC_IP}:8080/hello
  nc ${PUBLIC_IP} 9090

Terminate:
  aws ec2 terminate-instances --region $REGION --instance-ids $INSTANCE_ID
Clean up AMI + snapshot + S3:
  aws ec2 deregister-image --region $REGION --image-id $AMI_ID
  aws ec2 delete-snapshot --region $REGION --snapshot-id $SNAPSHOT_ID
  aws s3 rm s3://${BUCKET}/${S3_KEY}
MSG
