# Theia — project site

The GitHub Pages site for [Theia](https://github.com/wondrkid00/Project-Theia).
This is an orphan branch: it carries only the site, not the source tree.

```
index.html            the whole page
assets/css/style.css  styles
assets/img/           terrain renders + an editor screenshot
assets/graphs/        the graphs each render was made from
assets/logo/          logo files; mark.svg is recoloured to currentColor
```

## Regenerating the imagery

Every terrain image is real Theia output — no retouching and no external
renderer. Each one has its graph in `assets/graphs/`, so they can be reproduced
from `main`:

```sh
# from a checkout of main, with the site branch checked out alongside
swift build -c release

# hero
swift run -c release theia-viewer --shot hero.png \
  --shot-size 2400 --no-chrome --size 1024 --az 40 --el 14 --dist 1.55 \
  assets/graphs/hero.json

# gallery (peaks, caldera, downs)
swift run -c release theia-viewer --shot peaks.png \
  --shot-size 1400 --no-chrome --size 1024 --az 42 --el 16 --dist 1.5 \
  assets/graphs/peaks.json

# rivers wants a slightly higher angle so the carved network reads
swift run -c release theia-viewer --shot rivers.png \
  --shot-size 1400 --no-chrome --size 1024 --az 42 --el 26 --dist 1.6 \
  assets/graphs/rivers.json
```

`--no-chrome` drops the editor grid and axes, which are viewport furniture
rather than part of the terrain. `--shot-size` sets the output width; height
follows at 2:3.

The editor screenshot is a window capture of `theia-viewer` opened on
`assets/graphs/hero.json`.

## Local preview

```sh
python3 -m http.server 8000
```

Then open <http://localhost:8000>.
