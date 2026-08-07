# G KIDS style capsules

Generated deliverables:

- `output/G_KIDS_style_capsules.pdf` — visual merchandising boards grouped by style;
- `output/capsule_inventory.csv` — article-to-capsule mapping;
- `output/*.png` — individual capsule boards.
- `output/G_KIDS_outfit_sets.pdf` — coordinated top-and-bottom looks;
- `output/outfit_pairs.csv` — article mapping for every outfit;
- `output/outfit_sets/*.png` — individual outfit boards.

Rebuild the deliverables with:

```bash
python3 build_capsules.py /path/to/source.pdf output
python3 build_outfits.py /path/to/source.pdf output
```
