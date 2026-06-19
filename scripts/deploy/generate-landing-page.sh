#!/bin/sh
# Generate _site/index.html -- the repository landing page.
#
# Required env vars:
#   BASE_URL          e.g. https://org.github.io/repo
#   GITHUB_REPOSITORY e.g. org/repo (set by GitHub Actions)

set -eu

: "${BASE_URL:?BASE_URL must be set}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"

{
    cat <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>NetBSD Package Repository</title>
  <style>
    :root {
      color-scheme: light dark;
      --bg: #fff;
      --fg: #222;
      --code-bg: #f4f4f4;
      --link: #0366d6;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --bg: #0d1117;
        --fg: #c9d1d9;
        --code-bg: #161b22;
        --link: #58a6ff;
      }
    }
    body { font-family: system-ui, sans-serif; max-width: 48rem; margin: 2rem auto; padding: 0 1rem; line-height: 1.5; background: var(--bg); color: var(--fg); }
    h1 { margin-bottom: 0.25rem; }
    a { color: var(--link); }
    code, pre { background: var(--code-bg); border-radius: 3px; }
    code { padding: 0.1rem 0.3rem; }
    pre { padding: 1rem; overflow-x: auto; }
    ul { padding-left: 1.25rem; }
  </style>
</head>
<body>
  <h1>NetBSD Package Repository</h1>
  <p>Binary NetBSD pkgsrc packages built for CPU architectures not covered by the official NetBSD package mirrors.</p>

  <h2>Available targets</h2>
  <ul>
HTML

    for d in _site/NetBSD-*; do
        [ -d "$d" ] || continue
        abi=$(basename "$d")
        printf '    <li><a href="%s/"><code>%s</code></a></li>\n' "$abi" "$abi"
    done

    cat <<HTML
  </ul>

  <h2>Using the repository</h2>
  <p>On a matching NetBSD system, install with <code>pkg_add</code> by pointing
  <code>PKG_PATH</code> at the target's <code>All/</code> directory:</p>
<pre>export PKG_PATH="${BASE_URL}/NetBSD-&lt;version&gt;-&lt;arch&gt;/All"
pkg_add bash sudo curl rsync</pre>
  <p>No <code>pkgin</code> is required — these targets have no bootstrapped
  pkgin — but if it is installed you can add the same URL to
  <code>pkgin</code>'s <code>repositories.conf</code>.</p>

  <p><small>Source: <a href="https://github.com/${GITHUB_REPOSITORY}">${GITHUB_REPOSITORY}</a></small></p>
</body>
</html>
HTML
} > _site/index.html
