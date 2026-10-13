"""Generate AudioShare's phone-broadcast mark (Pillow required).

A tilted phone sends two warm sound arcs. Shared geometry and colors
keep SVG, Android adaptive/themed icons, legacy PNGs and Windows ICO consistent.
The adaptive mark stays inside the central 66dp launcher safe zone.
"""
from math import cos, radians, sin
from pathlib import Path

from PIL import Image, ImageColor, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
RES = 'android/app/src/main/res/'
BG_START, BG_END = '#FFF9F3', '#EFF5FF'
PHONE_START, PHONE_END = '#759CFF', '#5574E5'
SOUND_START, SOUND_END = '#FFB485', '#F78C78'
LEGACY_SCALE = 1.30


def tilt(commands):
    angle = radians(-9)
    result = []
    for command, *coordinates in commands:
        transformed = []
        for x, y in zip(coordinates[::2], coordinates[1::2]):
            x, y = x-39.5, y-54
            transformed.extend((round(39.5+x*cos(angle)-y*sin(angle), 3),
                                round(54+x*sin(angle)+y*cos(angle), 3)))
        result.append((command, *transformed))
    return result


PHONE = tilt([
    ('M', 35, 33), ('L', 44, 33),
    ('C', 47.314, 33, 50, 35.686, 50, 39), ('L', 50, 69),
    ('C', 50, 72.314, 47.314, 75, 44, 75), ('L', 35, 75),
    ('C', 31.686, 75, 29, 72.314, 29, 69), ('L', 29, 39),
    ('C', 29, 35.686, 31.686, 33, 35, 33),
])
# Path, stroke width, gradient endpoints. Two broad arcs remain legible at 16px.
SHAPES = [
    (PHONE, 5.5, PHONE_START, PHONE_END),
    (tilt([('M', 37.5, 67), ('L', 41.5, 67)]), 3, PHONE_START, PHONE_END),
    ([('M', 61, 43), ('C', 67.5, 48.5, 67.5, 59.5, 61, 65)],
     5.5, SOUND_START, SOUND_END),
    ([('M', 70, 35), ('C', 81.5, 44.5, 81.5, 63.5, 70, 73)],
     5.5, SOUND_START, SOUND_END),
]


def path_data(commands):
    return ' '.join(command[0] + ' ' + ' '.join(f'{n:g}' for n in command[1:])
                    for command in commands)


def write(path, content):
    destination = ROOT / path
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(content, encoding='utf-8')


def gradient_xml(attribute, start, end, first, last):
    return (f'<aapt:attr name="android:{attribute}"><gradient '
            f'android:type="linear" android:startX="{first[0]}" '
            f'android:startY="{first[1]}" android:endX="{last[0]}" '
            f'android:endY="{last[1]}" android:startColor="{start}" '
            f'android:endColor="{end}" /></aapt:attr>')


def vector(monochrome=False, background=False):
    parts = ['<vector xmlns:android="http://schemas.android.com/apk/res/android" '
             'xmlns:aapt="http://schemas.android.com/aapt" '
             'android:width="108dp" android:height="108dp" '
             'android:viewportWidth="108" android:viewportHeight="108">']
    if background:
        parts += ['  <path android:pathData="M0,0 H108 V108 H0 Z">',
                  '    ' + gradient_xml('fillColor', BG_START, BG_END, (0, 0), (108, 108)),
                  '  </path>']
    else:
        parts.append('  <group android:pivotX="54" android:pivotY="54" '
                     'android:scaleX="0.90" android:scaleY="0.90">')
        for commands, width, start, end in SHAPES:
            color = 'android:strokeColor="#FFFFFF" ' if monochrome else ''
            parts.append(f'    <path android:fillColor="@android:color/transparent" '
                         f'android:strokeWidth="{width}" android:strokeLineCap="round" '
                         f'android:strokeLineJoin="round" {color}'
                         f'android:pathData="{path_data(commands)}">')
            if not monochrome:
                parts.append('      ' + gradient_xml('strokeColor', start, end, (22, 54), (86, 54)))
            parts.append('    </path>')
        parts.append('  </group>')
    return '\n'.join(parts + ['</vector>\n'])


def points(commands):
    result = []
    for command in commands:
        if command[0] in ('M', 'L'):
            current = command[1:]
            result.append(current)
        else:
            origin = current
            a, b, current = command[1:3], command[3:5], command[5:7]
            for step in range(1, 81):
                t = step / 80
                result.append(tuple((1-t)**3 * origin[i] + 3*(1-t)**2*t*a[i]
                                    + 3*(1-t)*t*t*b[i] + t**3*current[i]
                                    for i in range(2)))
    return result


def gradient(size, start, end, diagonal=False):
    first, last = ImageColor.getrgb(start), ImageColor.getrgb(end)
    image = Image.new('RGBA', (size, size))
    pixels = image.load()
    for y in range(size):
        for x in range(size):
            if diagonal:
                t = (x+y) / (2*(size-1))
            else:
                t = ((x/(size-1)*108-54)/LEGACY_SCALE+54-22) / 64
            t = max(0, min(1, t))
            pixels[x, y] = tuple(round(a+(b-a)*t) for a, b in zip(first, last)) + (255,)
    return image


def raster(size):
    resolution = 864
    scale = resolution / 108
    image = gradient(resolution, BG_START, BG_END, diagonal=True)
    background_mask = Image.new('L', image.size)
    ImageDraw.Draw(background_mask).rounded_rectangle(
        (0, 0, resolution-1, resolution-1), radius=26*scale, fill=255)
    image.putalpha(background_mask)
    inks = {(start, end): gradient(resolution, start, end)
            for start, end in {(shape[2], shape[3]) for shape in SHAPES}}
    for commands, stroke, start, end in SHAPES:
        mask = Image.new('L', image.size)
        draw = ImageDraw.Draw(mask)
        width = round(stroke * LEGACY_SCALE * scale)
        xy = [tuple((54+(n-54)*LEGACY_SCALE)*scale for n in point)
              for point in points(commands)]
        draw.line(xy, fill=255, width=width, joint='curve')
        # Stamp every sampled point: Pillow's thick curved joins can leave
        # pinholes when many short Bezier segments meet.
        for x, y in xy:
            draw.ellipse((x-width/2, y-width/2, x+width/2, y+width/2), fill=255)
        image.paste(inks[start, end], (0, 0), mask)
    return image.resize((size, size), Image.Resampling.LANCZOS)


def main():
    svg = ['<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 108 108">',
           '<defs>',
           f'<linearGradient id="tile" x2="1" y2="1"><stop stop-color="{BG_START}"/>'
           f'<stop offset="1" stop-color="{BG_END}"/></linearGradient>',
           ]
    for index, (_, _, start, end) in enumerate(SHAPES):
        svg.append(f'<linearGradient id="ink{index}" gradientUnits="userSpaceOnUse" '
                   f'x1="22" y1="54" x2="86" y2="54"><stop stop-color="{start}"/>'
                   f'<stop offset="1" stop-color="{end}"/></linearGradient>')
    svg.extend(['</defs>', '<rect width="108" height="108" rx="26" fill="url(#tile)"/>',
           f'<g transform="translate(54 54) scale({LEGACY_SCALE}) translate(-54 -54)" '
           'fill="none" stroke-linecap="round" stroke-linejoin="round">'])
    svg.extend(f'<path d="{path_data(commands)}" stroke="url(#ink{index})" stroke-width="{width}"/>'
               for index, (commands, width, _, _) in enumerate(SHAPES))
    write('assets/icon/audioshare.svg', '\n'.join(svg + ['</g></svg>\n']))
    master = raster(1024)
    master.resize((512, 512), Image.Resampling.LANCZOS).save(ROOT / 'assets/icon/audioshare.png')
    write(RES+'drawable/ic_audioshare_background.xml', vector(background=True))
    write(RES+'drawable/ic_audioshare_foreground.xml', vector())
    write(RES+'drawable/ic_audioshare_monochrome.xml', vector(monochrome=True))
    write(RES+'values/icon_colors.xml', f'<resources><color name="launcher_background">{BG_START}</color></resources>\n')
    for version, monochrome in [('v26', ''), ('v33', '  <monochrome android:drawable="@drawable/ic_audioshare_monochrome" />\n')]:
        write(RES+f'mipmap-anydpi-{version}/ic_launcher.xml',
              '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
              '  <background android:drawable="@drawable/ic_audioshare_background" />\n'
              '  <foreground android:drawable="@drawable/ic_audioshare_foreground" />\n'
              +monochrome+'</adaptive-icon>\n')
    for density, size in [('mdpi', 48), ('hdpi', 72), ('xhdpi', 96), ('xxhdpi', 144), ('xxxhdpi', 192)]:
        master.resize((size, size), Image.Resampling.LANCZOS).save(ROOT / RES / f'mipmap-{density}/ic_launcher.png')
    master.save(ROOT / 'windows/runner/resources/app_icon.ico',
                sizes=[(size, size) for size in [16, 24, 32, 48, 64, 128, 256]])
    print('Generated phone-broadcast SVG/PNG, Android adaptive/themed icons and Windows ICO.')


if __name__ == '__main__':
    main()
