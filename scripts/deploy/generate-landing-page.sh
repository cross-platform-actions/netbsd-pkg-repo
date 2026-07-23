#!/bin/sh
# Generate _site/index.html -- the repository landing page.
#
# Packages are NOT served from Pages; they live as immutable GitHub release
# assets. This page is only an index: for each target it shows the newest
# release's copy-paste PKG_PATH plus how to verify it. Release data is read
# live via the GitHub CLI, so the page needs no build-matrix knowledge -- it
# reflects whatever releases exist.
#
# Required env vars:
#   GH_TOKEN          token with contents:read (github.token in Actions)
#   GITHUB_REPOSITORY owner/repo (set by GitHub Actions)

set -eu

: "${GH_TOKEN:?GH_TOKEN must be set}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must be set}"

mkdir -p _site

# Newest published release per ABI. Tags are <abi>--<version>; group by the
# part before `--` and keep the most recently created one. Drafts are excluded
# -- they are unreviewed and must never surface on the live site. Emits TSV:
# abi<TAB>tag<TAB>url.
latest_per_abi=$(
    gh release list --repo "$GITHUB_REPOSITORY" --limit 500 \
        --json tagName,createdAt,url,isDraft \
    | jq -r '
        map(select(.isDraft | not))
        | map(select(.tagName | test("--")))
        | map(. + {abi: (.tagName | split("--")[0])})
        | group_by(.abi)
        | map(max_by(.createdAt))
        | sort_by(.abi)
        | .[] | [.abi, .tagName, .url] | @tsv'
)

dl_base="https://github.com/${GITHUB_REPOSITORY}/releases/download"

{
    cat <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>NetBSD Package Repository</title>
  <style>
    :root {
      color-scheme: light dark;
      --bg: #fff;
      --fg: #222;
      --muted: #666;
      --code-bg: #f4f4f4;
      --border: #ccc;
      --link: #0366d6;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --bg: #0d1117;
        --fg: #c9d1d9;
        --muted: #8b949e;
        --code-bg: #161b22;
        --border: #30363d;
        --link: #58a6ff;
      }
    }
    body { font-family: system-ui, sans-serif; max-width: 52rem; margin: 2rem auto; padding: 0 1rem; line-height: 1.5; background: var(--bg); color: var(--fg); }
    h1 { margin-bottom: 0.25rem; }
    a { color: var(--link); }
    code, pre { background: var(--code-bg); border-radius: 3px; font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
    code { padding: 0.1rem 0.3rem; }
    pre { padding: 1rem; overflow-x: auto; }
    .target { border: 1px solid var(--border); border-radius: 6px; padding: 0.5rem 1rem; margin: 1rem 0; }
    .target h3 { margin: 0.5rem 0; font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
    .muted { color: var(--muted); }
  </style>
</head>
<body>
  <h1>NetBSD Package Repository</h1>
  <p>Binary NetBSD pkgsrc packages built for CPU architectures not covered by
  the official NetBSD package mirrors.</p>
  <p>Packages are published as <strong>immutable GitHub releases</strong>: once
  a release exists its assets are locked, its tag is protected, and GitHub
  provides a signed attestation you can verify. Pin the release you want and the
  bytes can never change under you.</p>

  <h2>Available targets</h2>
HTML

    if [ -z "$latest_per_abi" ]; then
        echo '  <p class="muted">No releases published yet.</p>'
    else
        printf '%s\n' "$latest_per_abi" | while IFS="$(printf '\t')" read -r abi tag url; do
            pkg_path="${dl_base}/${tag}"
            cat <<HTML
  <div class="target">
    <h3>${abi}</h3>
    <p>Latest release: <a href="${url}"><code>${tag}</code></a></p>
    <p>Point <code>PKG_PATH</code> at it and install with the base
    <code>pkg_add</code> (no pkgin bootstrap required):</p>
<pre>export PKG_PATH="${pkg_path}"
pkg_add bash sudo rsync</pre>
  </div>
HTML
        done
    fi

    cat <<HTML
  <h2>Pinning and verifying</h2>
  <p>Each release is an immutable dated snapshot. Pin a specific tag (the
  <code>PKG_PATH</code> above already does) so your build is reproducible, then
  verify the release and its assets against GitHub's signed attestation with the
  <a href="https://cli.github.com/">GitHub CLI</a>:</p>
<pre>gh release verify --repo ${GITHUB_REPOSITORY} &lt;tag&gt;
gh release verify-asset --repo ${GITHUB_REPOSITORY} &lt;tag&gt; &lt;package&gt;.tgz</pre>
  <p>Browse every version on the
  <a href="https://github.com/${GITHUB_REPOSITORY}/releases">releases page</a>.</p>

  <p><small>Source: <a href="https://github.com/${GITHUB_REPOSITORY}">${GITHUB_REPOSITORY}</a></small></p>
</body>
</html>
HTML
} > _site/index.html

echo "Wrote _site/index.html"
