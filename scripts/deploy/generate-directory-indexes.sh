#!/bin/sh
# Generate an index.html in every subdirectory of _site/, so the
# repository is browsable. The root _site/index.html (landing page) is
# preserved via `find -mindepth 1`.

set -eu

generate_index() {
    dir="$1"
    relpath="${dir#_site/}"
    {
        cat <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Index of /${relpath}/</title>
  <style>
    :root {
      color-scheme: light dark;
      --bg: #fff;
      --fg: #222;
      --muted: #666;
      --border: #ccc;
      --hover-bg: #f4f4f4;
      --link: #0366d6;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --bg: #0d1117;
        --fg: #c9d1d9;
        --muted: #8b949e;
        --border: #30363d;
        --hover-bg: #161b22;
        --link: #58a6ff;
      }
    }
    body { font-family: system-ui, sans-serif; max-width: 60rem; margin: 2rem auto; padding: 0 1rem; background: var(--bg); color: var(--fg); }
    h1 { font-size: 1.25rem; font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
    table { border-collapse: collapse; width: 100%; font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: 0.9rem; }
    th, td { text-align: left; padding: 0.15rem 0.75rem 0.15rem 0; }
    th { border-bottom: 1px solid var(--border); font-weight: 600; }
    tr:hover td { background: var(--hover-bg); }
    a { text-decoration: none; color: var(--link); }
    a:hover { text-decoration: underline; }
    .size { text-align: right; color: var(--muted); white-space: nowrap; }
  </style>
</head>
<body>
  <h1>Index of /${relpath}/</h1>
  <table>
    <thead><tr><th>Name</th><th class="size">Size</th></tr></thead>
    <tbody>
      <tr><td><a href="../">../</a></td><td class="size">-</td></tr>
HTML
        for entry in "$dir"/*/; do
            [ -d "$entry" ] || continue
            name=$(basename "$entry")
            printf '      <tr><td><a href="%s/">%s/</a></td><td class="size">-</td></tr>\n' "$name" "$name"
        done
        for entry in "$dir"/*; do
            [ -f "$entry" ] || continue
            name=$(basename "$entry")
            [ "$name" = index.html ] && continue
            size=$(stat -c%s "$entry")
            human=$(numfmt --to=iec-i --suffix=B --format='%.1f' "$size")
            printf '      <tr><td><a href="%s">%s</a></td><td class="size">%s</td></tr>\n' "$name" "$name" "$human"
        done
        cat <<'HTML'
    </tbody>
  </table>
</body>
</html>
HTML
    } > "$dir/index.html"
}

find _site -mindepth 1 -type d | while IFS= read -r d; do
    generate_index "$d"
done
