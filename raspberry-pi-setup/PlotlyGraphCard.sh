#!/usr/bin/env bash
# Shared Plotly Graph Card release staging and Lovelace registration helpers.
PLOTLY_GRAPH_CARD_REPO="dbuezas/lovelace-plotly-graph-card"
PLOTLY_GRAPH_CARD_VERSION="v4.0.2"
PLOTLY_GRAPH_CARD_RESOURCE="/local/plotly-graph-card/plotly-graph-card.js"

plotly_stage_release() {
    local dest_dir="$1" work_dir="$2"
    local metadata="$work_dir/plotly-release.json" asset_list="$work_dir/plotly-assets.tsv"
    mkdir -p "$dest_dir"
    curl -fsSL --retry 3 -H 'Accept: application/vnd.github+json' \
        "https://api.github.com/repos/$PLOTLY_GRAPH_CARD_REPO/releases/tags/$PLOTLY_GRAPH_CARD_VERSION" -o "$metadata"
    python3 - "$metadata" "$asset_list" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f: release = json.load(f)
if release.get("tag_name") != "v4.0.2": raise SystemExit("Unexpected Plotly release tag.")
assets = [a for a in release.get("assets", []) if a.get("name", "").endswith(".js")]
names = [a["name"] for a in assets]
if not assets or "plotly-graph-card.js" not in names: raise SystemExit("Release is missing Plotly JavaScript assets or its entry point.")
with open(sys.argv[2], "w", encoding="utf-8") as f:
    for a in assets:
        n, u = a["name"], a.get("browser_download_url", "")
        if not u or "/" in n or "\t" in n or "\n" in n: raise SystemExit("Invalid release asset metadata.")
        f.write(n + "\t" + u + "\n")
print("Release v4.0.2 JavaScript asset count:", len(assets))
PY
    while IFS=$'\t' read -r asset_name asset_url; do
        [[ -n "$asset_name" && -n "$asset_url" ]] || { echo "Invalid Plotly asset metadata." >&2; return 1; }
        curl -fsSL --retry 3 "$asset_url" -o "$dest_dir/$asset_name"
        [[ -s "$dest_dir/$asset_name" ]] || { echo "Empty Plotly asset: $asset_name" >&2; return 1; }
    done < "$asset_list"
    python3 - "$dest_dir" "$asset_list" <<'PY'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
expected = [x.split("\t", 1)[0] for x in pathlib.Path(sys.argv[2]).read_text().splitlines()]
missing = [n for n in expected if not (root/n).is_file() or (root/n).stat().st_size == 0]
if missing: raise SystemExit("Missing Plotly assets: " + ", ".join(missing))
entry = root/"plotly-graph-card.js"
required = {"rolldown-runtime-B0Z9INg1.js", "card-BgJGmfH_.js"}
if not required.issubset({p.name for p in root.glob("*.js")}): raise SystemExit("Required entry-point dependencies are missing.")
entry_text = entry.read_text(encoding="utf-8")
if any(name not in entry_text for name in required): raise SystemExit("Entry point does not contain the expected sibling imports.")
pattern = re.compile(r"""(?:\bimport\s*(?:\(\s*)?|\bfrom\s*)["']([^"']+)["']""")
bad = set()
for source in root.glob("*.js"):
    for spec in pattern.findall(source.read_text(encoding="utf-8", errors="replace")):
        if spec.startswith(("./", "../")):
            target = (source.parent/spec).resolve()
            try: target.relative_to(root.resolve())
            except ValueError: bad.add(source.name + " -> " + spec); continue
            if not target.is_file(): bad.add(source.name + " -> " + spec)
if bad: raise SystemExit("Unresolved relative imports:\n  " + "\n  ".join(sorted(bad)))
print("Validated", len(expected), "JavaScript assets and all relative imports.")
PY
}

plotly_ensure_lovelace_resource() {
    python3 - "$1" "$PLOTLY_GRAPH_CARD_RESOURCE" <<'PY'
import pathlib, re, sys
p, url = pathlib.Path(sys.argv[1]), sys.argv[2]
s = p.read_text(encoding="utf-8")
lines = s.splitlines(keepends=True)
roots = [i for i,x in enumerate(lines) if re.match(r"^lovelace\s*:", x)]
if len(roots) > 1: raise SystemExit("Multiple root lovelace sections; manual adjustment required.")
if not roots:
    p.write_text(s.rstrip() + "\n\n# Lovelace Plotly Graph Card resource\nlovelace:\n  resource_mode: yaml\n  resources:\n    - url: " + url + "\n      type: module\n", encoding="utf-8")
    print("Added root YAML Lovelace section and Plotly resource."); raise SystemExit(0)
start = roots[0]
if re.match(r"^lovelace\s*:\s*\S", lines[start]): raise SystemExit("Lovelace uses an include or unsupported value; manual adjustment required.")
end = next((i for i in range(start+1,len(lines)) if re.match(r"^[A-Za-z0-9_]+\s*:",lines[i])),len(lines))
block = lines[start:end]
if not any(re.match(r"^  resource_mode:\s*yaml\s*(?:#.*)?$",x.rstrip("\r\n")) for x in block): raise SystemExit("Existing Lovelace section must use resource_mode: yaml.")
r = [i for i,x in enumerate(block) if re.match(r"^  resources:\s*(?:#.*)?$",x.rstrip("\r\n"))]
if len(r) != 1: raise SystemExit("Expected one root-level lovelace.resources list; manual adjustment required.")
matches = [i for i,x in enumerate(block) if re.match(r"^\s*-\s+url:\s*" + re.escape(url) + r"\s*(?:#.*)?$",x.rstrip("\r\n"))]
if len(matches)>1: raise SystemExit("Duplicate Plotly resource entries; manual adjustment required.")
if matches: print("Plotly resource already registered exactly once."); raise SystemExit(0)
insert = len(block)
for i in range(r[0]+1,len(block)):
    if re.match(r"^  [A-Za-z0-9_]+\s*:",block[i]): insert=i; break
block[insert:insert] = ["    - url: " + url + "\n", "      type: module\n"]
lines[start:end] = block
p.write_text("".join(lines),encoding="utf-8")
print("Added Plotly resource to existing YAML Lovelace resources.")
PY
}

plotly_install_bundle_atomic() {
    local staged="$1" target="$2" owner="\${3:-}"
    local parent tmp backup=""
    parent="$(dirname "$target")"
    mkdir -p "$parent"
    tmp="$(mktemp -d "$parent/.plotly-stage.XXXXXX")"
    if [[ -d "$target" ]]; then cp -a "$target/." "$tmp/"; fi
    find "$tmp" -maxdepth 1 -type f -name '*.js' -delete
    find "$staged" -maxdepth 1 -type f -name '*.js' -exec install -m 0644 {} "$tmp/" \;
    chmod 0755 "$tmp"
    [[ -z "$owner" ]] || chown -R "$owner" "$tmp"
    if [[ -e "$target" ]]; then backup="$parent/.plotly-backup.$(date +%Y%m%d-%H%M%S).$$"; mv "$target" "$backup"; fi
    if mv "$tmp" "$target"; then
        [[ -z "$backup" ]] || rm -rf "$backup"
    else
        [[ -z "$backup" ]] || mv "$backup" "$target"
        rm -rf "$tmp"
        return 1
    fi
}
