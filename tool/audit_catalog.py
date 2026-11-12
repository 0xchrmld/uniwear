#!/usr/bin/env python3
"""Verify the deployed SQL catalog seed against the supplied pricing audit."""
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
MIGRATION = ROOT / "supabase/migrations/20261112145828_initial_uniwear_backend.sql"
AUDIT = ROOT / "PRICING_AND_PHOTOS_AUDIT.md"

# Product display names in the audit mapped to the stable ids used by the app.
IDS = {
    "Female SHS Vest": "shs-f-vest",
    "Male SHS Vest": "shs-m-vest",
    "H.S. Blouse": "hs-blouse",
    "NEU Skirt": "neu-skirt",
    "NEU Pants": "neu-pants",
    "Female Necktie": "female-tie",
    "Junior Necktie": "junior-tie",
    "College Skirt": "college-skirt",
    "College Polo": "college-polo",
    "College Pants": "college-pants",
}

sql = MIGRATION.read_text()
audit = AUDIT.read_text()

product_block = sql.split("insert into public.products", 1)[1].split("insert into public.product_prices", 1)[0]
product_rows = re.findall(
    r"\('([^']+)',\s*'[^']+',\s*'[^']+',\s*'[^']+',\s*'([^']+)'",
    product_block,
)
product_ids = [row[0] for row in product_rows]
product_images = {row[1] for row in product_rows}
price_block = sql.split("insert into public.product_prices", 1)[1]
seed_prices = {
    (product_id, size): int(price)
    for product_id, size, price in re.findall(
        r"\('([^']+)',\s*'([^']+)',\s*(\d+),\s*\d+\)", price_block
    )
}

audit_prices = {}
for line in audit.splitlines():
    if not line.startswith("- "):
        continue
    for part in line[2:].split(";"):
        match = re.match(r"([^:]+):\s*(.+)$", part.strip())
        if not match or match.group(1) not in IDS:
            continue
        product_id = IDS[match.group(1)]
        for size, price in re.findall(r"([^,=]+?)\s*=\s*(\d+)", match.group(2)):
            audit_prices[(product_id, size.strip())] = int(price)

missing = sorted(set(audit_prices) - set(seed_prices))
extra = sorted(set(seed_prices) - set(audit_prices))
mismatched = sorted(
    (key, audit_prices[key], seed_prices[key])
    for key in set(audit_prices) & set(seed_prices)
    if audit_prices[key] != seed_prices[key]
)

assert len(product_ids) == 12, f"Expected 12 products, found {len(product_ids)}"
assert len(set(product_ids)) == 12, "Duplicate product ids in product seed"
assert "college-blouse" not in product_ids and "polo-with-patch" not in product_ids
assert len(seed_prices) == 65, f"Expected 65 priced sizes, found {len(seed_prices)}"
missing_images = sorted(
    image for image in product_images if not (ROOT / "assets/products" / image).is_file()
)
assert not missing_images, f"Missing bundled product images: {missing_images}"
assert not missing, f"Missing prices from seed: {missing}"
assert not extra, f"Unexpected prices in seed: {extra}"
assert not mismatched, f"Price differences (audit, seed): {mismatched}"
assert "integrated-pe-shirt" in product_ids and "integrated-pe-pants" in product_ids
assert not any(pid.startswith("integrated-pe-") for pid, _ in seed_prices)

print(f"PASS — {len(product_ids)} products, {len(seed_prices)} price rows match the audit.")
print(f"PASS — {len(product_images)} product image assets exist.")
print("PASS — both P.E. products are view-only; excluded catalog entries are absent.")
