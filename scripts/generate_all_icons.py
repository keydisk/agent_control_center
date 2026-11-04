import os
import shutil
import subprocess
from PIL import Image, ImageDraw, ImageFilter
import numpy as np
from collections import deque

BASE_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS_DIR = os.path.join(BASE_DIR, 'assets', 'icons')
os.makedirs(ASSETS_DIR, exist_ok=True)

APP_RAW = '/Users/juyoungchoi/.gemini/antigravity/brain/eb1fc760-baf2-4293-b65c-f8f3d948f028/agent_control_center_app_icon_1793685790802.jpg'
FOLDER_RAW = '/Users/juyoungchoi/.gemini/antigravity/brain/eb1fc760-baf2-4293-b65c-f8f3d948f028/agent_control_center_macos_folder_1793685897000.jpg'
FOLDER_3D_RAW = '/Users/juyoungchoi/.gemini/antigravity/brain/eb1fc760-baf2-4293-b65c-f8f3d948f028/agent_control_center_folder_icon_1793685811701.jpg'

def generate_folder_icon():
    print("[1/3] Generating Front macOS Folder Icon...")
    img = Image.open(FOLDER_RAW).convert('RGB')
    arr = np.array(img).astype(float)
    h, w, _ = arr.shape
    diff_from_white = 255.0 - np.min(arr, axis=2)

    visited = np.zeros((h, w), dtype=bool)
    queue = deque()

    for x in range(w):
        if diff_from_white[0, x] < 20:
            visited[0, x] = True
            queue.append((0, x))
        if diff_from_white[h-1, x] < 20:
            visited[h-1, x] = True
            queue.append((h-1, x))
    for y in range(h):
        if diff_from_white[y, 0] < 20:
            visited[y, 0] = True
            queue.append((y, 0))
        if diff_from_white[y, w-1] < 20:
            visited[y, w-1] = True
            queue.append((y, w-1))

    while queue:
        cy, cx = queue.popleft()
        for dy, dx in [(-1,0), (1,0), (0,-1), (0,1)]:
            ny, nx = cy + dy, cx + dx
            if 0 <= ny < h and 0 <= nx < w and not visited[ny, nx]:
                if diff_from_white[ny, nx] < 35:
                    visited[ny, nx] = True
                    queue.append((ny, nx))

    alpha = np.ones((h, w), dtype=float) * 255.0
    shadow_alpha = np.clip(diff_from_white * 1.5, 0, 255)
    alpha[visited] = np.where(diff_from_white[visited] > 2, shadow_alpha[visited], 0)

    a_norm = alpha / 255.0
    a_norm_safe = np.maximum(a_norm, 0.001)[:, :, np.newaxis]

    clean_rgb = arr.copy()
    border_mask = (alpha > 0) & (alpha < 255)
    unmultiplied = (arr - (1.0 - a_norm_safe) * 255.0) / a_norm_safe
    unmultiplied = np.clip(unmultiplied, 0, 255)
    clean_rgb[border_mask] = unmultiplied[border_mask]

    shadow_mask = visited & (alpha > 0)
    clean_rgb[shadow_mask] = [0, 0, 0]

    res = np.dstack([clean_rgb.astype(np.uint8), alpha.astype(np.uint8)])
    out_img = Image.fromarray(res)
    out_master = os.path.join(ASSETS_DIR, 'folder_icon.png')
    out_img.save(out_master, 'PNG')
    print(f" -> Master Folder Icon saved: {out_master}")
    return out_img

def generate_folder_3d_icon():
    print("[2/3] Generating 3D macOS Folder Icon...")
    img = Image.open(FOLDER_3D_RAW).convert('RGB')
    arr = np.array(img).astype(float)
    h, w, _ = arr.shape

    corners = [arr[0,0], arr[0,w-1], arr[h-1,0], arr[h-1,w-1]]
    bg_ref = np.mean(corners, axis=0)
    diff = np.linalg.norm(arr - bg_ref, axis=2)

    visited = np.zeros((h, w), dtype=bool)
    queue = deque()

    for x in range(w):
        if diff[0, x] < 30:
            visited[0, x] = True
            queue.append((0, x))
        if diff[h-1, x] < 30:
            visited[h-1, x] = True
            queue.append((h-1, x))
    for y in range(h):
        if diff[y, 0] < 30:
            visited[y, 0] = True
            queue.append((y, 0))
        if diff[y, w-1] < 30:
            visited[y, w-1] = True
            queue.append((y, w-1))

    while queue:
        cy, cx = queue.popleft()
        for dy, dx in [(-1,0), (1,0), (0,-1), (0,1)]:
            ny, nx = cy + dy, cx + dx
            if 0 <= ny < h and 0 <= nx < w and not visited[ny, nx]:
                if diff[ny, nx] < 35:
                    visited[ny, nx] = True
                    queue.append((ny, nx))

    alpha = np.ones((h, w), dtype=float) * 255.0
    alpha[visited] = 0

    alpha_img = Image.fromarray(alpha.astype(np.uint8))
    alpha_img = alpha_img.filter(ImageFilter.GaussianBlur(radius=0.8))

    img = img.convert('RGBA')
    img.putalpha(alpha_img)
    out_master = os.path.join(ASSETS_DIR, 'folder_icon_3d.png')
    img.save(out_master, 'PNG')
    print(f" -> Master 3D Folder Icon saved: {out_master}")
    return img

def create_icns(img, output_icns_path):
    iconset_dir = output_icns_path.replace('.icns', '.iconset')
    os.makedirs(iconset_dir, exist_ok=True)
    sizes = [
        (16, 'icon_16x16.png'),
        (32, 'icon_16x16@2x.png'),
        (32, 'icon_32x32.png'),
        (64, 'icon_32x32@2x.png'),
        (128, 'icon_128x128.png'),
        (256, 'icon_128x128@2x.png'),
        (256, 'icon_256x256.png'),
        (512, 'icon_256x256@2x.png'),
        (512, 'icon_512x512.png'),
        (1024, 'icon_512x512@2x.png'),
    ]
    for size, name in sizes:
        resized = img.resize((size, size), Image.Resampling.LANCZOS)
        resized.save(os.path.join(iconset_dir, name), 'PNG')

    subprocess.run(['iconutil', '-c', 'icns', iconset_dir, '-o', output_icns_path], check=True)
    shutil.rmtree(iconset_dir)
    print(f" -> ICNS created: {output_icns_path}")

def update_platform_icons(folder_img):
    print("[3/3] Updating platform specific App Icons to match Folder Icon (macOS, iOS, Android, Web, Windows)...")

    # Save as primary app_icon.png
    primary_app_png = os.path.join(ASSETS_DIR, 'app_icon.png')
    folder_img.save(primary_app_png, 'PNG')
    print(f" -> Saved primary app_icon.png from folder icon: {primary_app_png}")

    # 1. macOS Assets (Native transparent folder icon)
    macos_dir = os.path.join(BASE_DIR, 'macos', 'Runner', 'Assets.xcassets', 'AppIcon.appiconset')
    if os.path.exists(macos_dir):
        mac_sizes = {
            'app_icon_16.png': 16,
            'app_icon_32.png': 32,
            'app_icon_64.png': 64,
            'app_icon_128.png': 128,
            'app_icon_256.png': 256,
            'app_icon_512.png': 512,
            'app_icon_1024.png': 1024,
        }
        for fname, size in mac_sizes.items():
            folder_img.resize((size, size), Image.Resampling.LANCZOS).save(os.path.join(macos_dir, fname), 'PNG')
        print(" -> macOS xcassets updated with Folder Icon.")

    # 2. iOS Assets (iOS requires non-transparent background for App Store standard)
    # We create a sleek dark slate background version for iOS
    ios_base = Image.new('RGB', (1024, 1024), (13, 17, 23))
    ios_base.paste(folder_img, (0, 0), folder_img)

    ios_dir = os.path.join(BASE_DIR, 'ios', 'Runner', 'Assets.xcassets', 'AppIcon.appiconset')
    if os.path.exists(ios_dir):
        ios_sizes = {
            'Icon-App-20x20@1x.png': 20,
            'Icon-App-20x20@2x.png': 40,
            'Icon-App-20x20@3x.png': 60,
            'Icon-App-29x29@1x.png': 29,
            'Icon-App-29x29@2x.png': 58,
            'Icon-App-29x29@3x.png': 87,
            'Icon-App-40x40@1x.png': 40,
            'Icon-App-40x40@2x.png': 80,
            'Icon-App-40x40@3x.png': 120,
            'Icon-App-60x60@2x.png': 120,
            'Icon-App-60x60@3x.png': 180,
            'Icon-App-76x76@1x.png': 76,
            'Icon-App-76x76@2x.png': 152,
            'Icon-App-83.5x83.5@2x.png': 167,
            'Icon-App-1024x1024@1x.png': 1024,
        }
        for fname, size in ios_sizes.items():
            ios_base.resize((size, size), Image.Resampling.LANCZOS).save(os.path.join(ios_dir, fname), 'PNG')
        print(" -> iOS xcassets updated with Folder Icon.")

    # 3. Android mipmap (adaptive / transparent)
    android_res = os.path.join(BASE_DIR, 'android', 'app', 'src', 'main', 'res')
    if os.path.exists(android_res):
        android_sizes = {
            'mipmap-mdpi': 48,
            'mipmap-hdpi': 72,
            'mipmap-xhdpi': 96,
            'mipmap-xxhdpi': 144,
            'mipmap-xxxhdpi': 192,
        }
        for folder, size in android_sizes.items():
            target_f = os.path.join(android_res, folder, 'ic_launcher.png')
            os.makedirs(os.path.dirname(target_f), exist_ok=True)
            folder_img.resize((size, size), Image.Resampling.LANCZOS).save(target_f, 'PNG')
        print(" -> Android mipmap launcher icons updated.")

    # 4. Web icons & favicon
    web_dir = os.path.join(BASE_DIR, 'web')
    if os.path.exists(web_dir):
        folder_img.resize((32, 32), Image.Resampling.LANCZOS).save(os.path.join(web_dir, 'favicon.png'), 'PNG')
        web_icons_dir = os.path.join(web_dir, 'icons')
        os.makedirs(web_icons_dir, exist_ok=True)
        folder_img.resize((192, 192), Image.Resampling.LANCZOS).save(os.path.join(web_icons_dir, 'Icon-192.png'), 'PNG')
        folder_img.resize((512, 512), Image.Resampling.LANCZOS).save(os.path.join(web_icons_dir, 'Icon-512.png'), 'PNG')
        folder_img.resize((192, 192), Image.Resampling.LANCZOS).save(os.path.join(web_icons_dir, 'Icon-maskable-192.png'), 'PNG')
        folder_img.resize((512, 512), Image.Resampling.LANCZOS).save(os.path.join(web_icons_dir, 'Icon-maskable-512.png'), 'PNG')
        print(" -> Web favicon and icons updated.")

    # 5. Windows .ico
    windows_res = os.path.join(BASE_DIR, 'windows', 'runner', 'resources')
    if os.path.exists(windows_res):
        ico_path = os.path.join(windows_res, 'app_icon.ico')
        ico_sizes = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
        folder_img.save(ico_path, format='ICO', sizes=ico_sizes)
        folder_img.save(os.path.join(ASSETS_DIR, 'app_icon.ico'), format='ICO', sizes=ico_sizes)
        print(" -> Windows app_icon.ico updated.")

def main():
    folder_img = generate_folder_icon()
    folder_3d_img = generate_folder_3d_icon()

    # Create app_icon.icns and folder_icon.icns both from the folder design
    create_icns(folder_img, os.path.join(ASSETS_DIR, 'app_icon.icns'))
    create_icns(folder_img, os.path.join(ASSETS_DIR, 'folder_icon.icns'))
    create_icns(folder_3d_img, os.path.join(ASSETS_DIR, 'folder_icon_3d.icns'))

    # Update platform app icons across macOS, iOS, Android, Web, Windows
    update_platform_icons(folder_img)

    print("\n✅ App icon has been registered identically to Folder Icon across all platforms!")

if __name__ == '__main__':
    main()
