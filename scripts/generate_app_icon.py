"""Generate AudioShare's geometric phone + audio monitor icon (Pillow required).

The same primitives produce the editable SVG, Android adaptive vectors, legacy
launcher PNGs and Windows ICO. No generated image or external logo is used.
"""
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
BG, WHITE, MINT = '#18483f', '#f2fbf6', '#8ee8c2'
# type, coordinates, corner radius / stroke width, color
SHAPES = [
    ('rect', (35, 33, 81, 65), 5, WHITE),
    ('rect', (39, 37, 77, 60), 2, BG),
    ('rect', (54, 64, 61, 71), 1, WHITE),
    ('rect', (45, 70, 70, 74), 2, WHITE),
    ('line', (47, 47, 47, 51), 3, MINT),
    ('line', (54, 43, 54, 55), 3, MINT),
    ('line', (61, 45, 61, 53), 3, MINT),
    ('line', (68, 48, 68, 50), 3, MINT),
    ('rect', (24, 44, 46, 80), 6, BG),
    ('rect', (27, 47, 43, 77), 4, WHITE),
    ('rect', (30, 51, 40, 69), 1, BG),
    ('line', (33, 73, 37, 73), 2, BG),
]


def path_for(shape):
    kind, (x, y, right, bottom), r, _ = shape
    if kind == 'line':
        return f'M {x},{y} L {right},{bottom}'
    return (f'M {x+r},{y} H {right-r} Q {right},{y} {right},{y+r} '
            f'V {bottom-r} Q {right},{bottom} {right-r},{bottom} '
            f'H {x+r} Q {x},{bottom} {x},{bottom-r} '
            f'V {y+r} Q {x},{y} {x+r},{y} Z')


def vector(monochrome=False):
    parts = ['<vector xmlns:android="http://schemas.android.com/apk/res/android" '
             'android:width="108dp" android:height="108dp" '
             'android:viewportWidth="108" android:viewportHeight="108">']
    for shape in SHAPES:
        kind, _, width, color = shape
        if monochrome:
            # Background-colored cutouts erase the filled shape via transparent
            # even-odd paths, supplied separately below for themed icons.
            continue
        attr = (f'android:strokeColor="{color}" android:strokeWidth="{width}" '
                'android:strokeLineCap="round"' if kind == 'line'
                else f'android:fillColor="{color}"')
        parts.append(f'  <path {attr} android:pathData="{path_for(shape)}" />')
    if monochrome:
        parts.append('  <path android:fillColor="#ffffff" android:fillType="evenOdd" '
            'android:pathData="M35,33 H81 V65 H61 V70 H70 V74 H46 V70 H54 V65 H46 V60 H77 V37 H39 V44 H35 Z '
            'M27,47 H43 V77 H27 Z M30,51 V69 H40 V51 Z M33,72 V74 H37 V72 Z '
            'M46,46 H49 V52 H46 Z M53,42 H56 V56 H53 Z M60,44 H63 V54 H60 Z M67,47 H70 V51 H67 Z" />')
    return '\n'.join(parts + ['</vector>\n'])


def write(path, content):
    dest = ROOT / path
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(content, encoding='utf-8')


def raster(size, rounded=True):
    scale = 10
    image = Image.new('RGBA', (108*scale, 108*scale))
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle((0, 0, 108*scale-1, 108*scale-1),
                           radius=24*scale if rounded else 0, fill=BG)
    for kind, coords, width, color in SHAPES:
        # Enlarge legacy artwork; adaptive vectors retain the mask-safe inset.
        xy = tuple((54 + (n-54)*1.35)*scale for n in coords)
        if kind == 'rect':
            draw.rounded_rectangle(xy, radius=width*scale*1.35, fill=color)
        else:
            stroke = round(width*scale*1.35)
            draw.line(xy, fill=color, width=stroke)
            for x, y in [(xy[0], xy[1]), (xy[2], xy[3])]:
                draw.ellipse((x-stroke/2, y-stroke/2, x+stroke/2, y+stroke/2), fill=color)
    return image.resize((size, size), Image.Resampling.LANCZOS)


svg = ['<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 108 108">',
       f'<rect width="108" height="108" rx="24" fill="{BG}"/>',
       '<g transform="translate(54 54) scale(1.35) translate(-54 -54)">']
for shape in SHAPES:
    kind, _, width, color = shape
    attr = f'fill="{color}"' if kind == 'rect' else f'fill="none" stroke="{color}" stroke-width="{width}" stroke-linecap="round"'
    svg.append(f'<path {attr} d="{path_for(shape)}"/>')
write('assets/icon/audioshare.svg', '\n'.join(svg + ['</g></svg>\n']))
raster(512).save(ROOT / 'assets/icon/audioshare.png')
res = 'android/app/src/main/res/'
write(res+'drawable/ic_audioshare_foreground.xml', vector())
write(res+'drawable/ic_audioshare_monochrome.xml', vector(True))
write(res+'values/icon_colors.xml', f'<resources><color name="launcher_background">{BG}</color></resources>\n')
for version, monochrome in [('v26', ''), ('v33', '  <monochrome android:drawable="@drawable/ic_audioshare_monochrome" />\n')]:
    write(res+f'mipmap-anydpi-{version}/ic_launcher.xml',
          '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
          '  <background android:drawable="@color/launcher_background" />\n'
          '  <foreground android:drawable="@drawable/ic_audioshare_foreground" />\n'
          +monochrome+'</adaptive-icon>\n')
for density, size in [('mdpi',48),('hdpi',72),('xhdpi',96),('xxhdpi',144),('xxxhdpi',192)]:
    raster(size).save(ROOT/res/f'mipmap-{density}/ic_launcher.png')
raster(256).save(ROOT/'windows/runner/resources/app_icon.ico', sizes=[(s,s) for s in [16,24,32,48,64,128,256]])
print('Generated Android adaptive/legacy icons, Windows ICO and SVG/PNG preview.')
