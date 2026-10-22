# RIP: cloud-icons.onemodel.app — Azure AI + Machine Learning

**Source:** https://cloud-icons.onemodel.app/azure/ai_+_machine_learning  
**Method:** Glider `bexplore` (session-3) → Gatsby `page-data.json` → direct SVG fetch  
**Date:** 2026-07-05

## What this site is

Gatsby static site (Netlify). Icons are **already SVG**. No bg removal or trace needed for this source.

## API surface (the rip)

Category index lists icons with paths:

```
GET https://cloud-icons.onemodel.app/page-data/azure/ai_+_machine_learning/page-data.json
→ result.pageContext.icons[].{ name, slug, path, id }
```

SVG URL pattern:

```
https://cloud-icons.onemodel.app/{url-encoded path}
```

Example: `azure/ai + machine learning/00028-icon-service-Batch-AI.svg`

## Provider indexes

```
/page-data/azure/page-data.json     → categories[]
/page-data/aws/page-data.json       → categories[]
/page-data/google/page-data.json    → categories[]
```

Each category page-data: `/page-data/{provider}/{category_slug}/page-data.json`

## Downloaded (this rip)

- **27/27** SVGs → `svgs/azure-*.svg`
- Manifest → `extracted/icons-manifest.json`
- Glider artifacts → `site.har`, `report.json`, screenshots

## Next step for your library

Copy `svgs/` → `icons/`, run squircle build for gallery webp. Repeat per category or script all Azure/AWS/GCP categories from page-data indexes.
