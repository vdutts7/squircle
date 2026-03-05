## Install squircle (one-time, for use anywhere)

Copy the script and its deps to `$CURTOOLS` so you can run it from any directory:

```bash
cp /path/to/webp/bin/squircle.sh /path/to/webp/bin/get-bg-color.sh /path/to/webp/bin/mask.png "$CURTOOLS/"
```

Add to your shell rc (e.g. `~/.zshrc`):

```bash
alias squircle='$CURTOOLS/squircle.sh'
```

Then from anywhere: `squircle <file>` (default out: same dir as input, .webp) or `squircle <file> --out <path>`.

## After clone (this repo, one-time)

```bash
.hooks/scripts/setup.sh
```

**Deps:** ImageMagick (`magick`). Optional: `exiftool` for metadata strip.

## Add icon

In this repo (with `WEBP` set to repo root, or pass `--out`):

```bash
cp ~/Downloads/newicon.png webp/
squircle webp/newicon.png
# or: squircle webp/newicon.png --out webp/newicon.webp
git add webp/newicon.webp
git commit -m "add newicon"
git push
```

If you don’t have the alias, run `./bin/squircle.sh webp/newicon.png` from repo root. Use subdirs for namespaces: `webp/aws/`, `webp/macos/`. Commit is blocked if you stage non-WebP or non-1024×1024 images under `webp/`. Normalize first.

## Use

```markdown
![icon](https://raw.githubusercontent.com/vdutts7/webp/main/webp/iconname.webp)
```
