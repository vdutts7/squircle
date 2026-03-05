# webp

Personal icon CDN. Icons: 1024×1024 squircle WebP under `webp/` (subdirs: `webp/aws/`, `webp/macos/`).

```yaml
# One-time
install_squircle: "cp bin/squircle.sh bin/get-bg-color.sh bin/mask.png $CURTOOLS/"
alias: "squircle='$CURTOOLS/squircle.sh'"
after_clone: ".hooks/scripts/setup.sh"
deps: ["magick", "exiftool (optional)"]

# Add icon
add:
  - "cp $DL/newicon.png webp/"
  - "squircle webp/newicon.png"
  - "git add webp/newicon.webp && git commit -m 'add newicon' && git push"

# CDN URL
url: "https://raw.githubusercontent.com/vdutts7/webp/main/webp/{name}.webp"
example: "![icon](https://raw.githubusercontent.com/vdutts7/webp/main/webp/iconname.webp)"
```

Pre-commit: only staged files under `webp/` checked; must be 1024×1024 `.webp`. No alias → `./bin/squircle.sh`.
