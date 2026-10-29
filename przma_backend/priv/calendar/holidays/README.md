# Holiday data

One JSON file per region (or any split you like). Every `*.json` file in
this folder is loaded by `Przma.Calendar.Holidays.import_bundled/0`.

Each file is an array of:

```json
{
  "region": "IN_TN",
  "date": "2027-01-15",
  "name": "Thai Pongal",
  "holiday_kind": "public"
}
```

- `region`: `IN` (national) or `IN_TN` (country_state). A calendar whose
  region is `IN_TN` shows both `IN` and `IN_TN` holidays.
- `date`: `YYYY-MM-DD` (local date).
- `holiday_kind`: `public` | `optional` | `festival`.

`IN.json` only contains the fixed-date national holidays. Festival dates
(Pongal, Deepavali, Ramzan, ...) change every year: add them in an
`IN_TN.json` file from the Tamil Nadu government's official holiday list
for that year. Do not guess these dates.

Re-importing is safe: the row id is `{region}-{yyyymmdd}-{name slug}`, so
the same holiday is overwritten, not duplicated.
