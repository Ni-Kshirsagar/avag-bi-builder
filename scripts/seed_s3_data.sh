#!/usr/bin/env bash
# Seed the primary data bucket with the AVAG sample datasets the Glue crawlers
# expect. Uploads:
#   POC/data/vehicle-models.csv  → avag-vehicles/vehicle-models/
#   POC/data/sales.csv           → avag-vehicles/sales/
#   POC/data/dealerships.csv     → avag-vehicles/dealerships/
#
# The Glue crawler for avag_vehicles_db points at s3://<bucket>/avag-vehicles/
# and auto-discovers each sub-prefix as a separate table.
#
# Idempotent: `aws s3 cp` safely overwrites, so re-running is harmless.
# Missing local files produce a warning but do NOT fail the deploy.
#
# Usage:
#   ./scripts/seed_s3_data.sh <bucket-name>
#   PRIMARY_DATA_BUCKET_NAME=<bucket> ./scripts/seed_s3_data.sh
set -euo pipefail

REGION="${AWS_REGION:-eu-north-1}"

BUCKET="${1:-${PRIMARY_DATA_BUCKET_NAME:-}}"
if [[ -z "$BUCKET" ]]; then
  echo "❌ seed_s3_data.sh: no bucket provided (pass as \$1 or set PRIMARY_DATA_BUCKET_NAME)" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"

VEHICLES_FILE="$ROOT/POC/data/vehicle-models.csv"
SALES_FILE="$ROOT/POC/data/sales.csv"
DEALERSHIPS_FILE="$ROOT/POC/data/dealerships.csv"

echo "Seeding AVAG data into s3://${BUCKET}/avag-vehicles/ (region ${REGION})..."

if [[ -f "$VEHICLES_FILE" ]]; then
  echo "  avag-vehicles/vehicle-models/ ← $VEHICLES_FILE"
  aws s3 cp "$VEHICLES_FILE" "s3://${BUCKET}/avag-vehicles/vehicle-models/" --region "$REGION"
else
  echo "⚠️  Missing $VEHICLES_FILE — skipping vehicle-models seed"
fi

if [[ -f "$SALES_FILE" ]]; then
  echo "  avag-vehicles/sales/          ← $SALES_FILE"
  aws s3 cp "$SALES_FILE" "s3://${BUCKET}/avag-vehicles/sales/" --region "$REGION"
else
  echo "⚠️  Missing $SALES_FILE — skipping sales seed"
fi

if [[ -f "$DEALERSHIPS_FILE" ]]; then
  echo "  avag-vehicles/dealerships/    ← $DEALERSHIPS_FILE"
  aws s3 cp "$DEALERSHIPS_FILE" "s3://${BUCKET}/avag-vehicles/dealerships/" --region "$REGION"
else
  echo "⚠️  Missing $DEALERSHIPS_FILE — skipping dealerships seed"
fi

echo "✓ AVAG data seeding complete"
