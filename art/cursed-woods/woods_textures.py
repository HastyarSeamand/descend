"""Paint the two shared Woods material sheets. Coordinates use a lower-left UV origin."""

import struct
import zlib

import numpy as np

SIZE = 512
GUTTER = 12
INNER = SIZE - 2 * GUTTER
AXIS = (np.arange(INNER, dtype=np.float32) + 0.5) / INNER
U, V = np.meshgrid(AXIS, AXIS)
ATLASES = {
    "Deadwood": ("Bark", "Endgrain", "Moss", "Fungus"),
    "Roadside": ("Slate", "Carving", "Iron", "Amber"),
}


def remap(value, low, high):
    value = np.clip((value - low) / (high - low), 0, 1)
    return value * value * (3 - 2 * value)


def noise(seed, nx, ny, u=U, v=V):
    grid = np.random.default_rng(seed).random((ny, nx), dtype=np.float32)
    x, y = u * nx, v * ny
    ix, iy = np.floor(x).astype(int), np.floor(y).astype(int)
    fx, fy = remap(x - ix, 0, 1), remap(y - iy, 0, 1)
    bottom = grid[iy % ny, ix % nx] * (1 - fx) + grid[iy % ny, (ix + 1) % nx] * fx
    top = grid[(iy + 1) % ny, ix % nx] * (1 - fx) + grid[(iy + 1) % ny, (ix + 1) % nx] * fx
    return bottom * (1 - fy) + top * fy


def palette(t, dark, middle, light):
    t = np.clip(t, 0, 1)
    colors = np.array([dark, middle, light], dtype=np.float32) / 255
    return np.stack([np.interp(t, [0, 0.55, 1], channel) for channel in colors.T], -1)


def mix(a, b, weight):
    return a + (b - a) * weight[..., None]


def score(segments, width):
    distance = np.ones_like(U)
    for (ax, ay), (bx, by) in segments:
        dx, dy = bx - ax, by - ay
        t = np.clip(((U - ax) * dx + (V - ay) * dy) / (dx * dx + dy * dy), 0, 1)
        distance = np.minimum(distance, np.hypot(U - ax - dx * t, V - ay - dy * t))
    return 1 - remap(distance, width * 0.35, width)


def paint(name):
    grain = noise(141, 104, 104)
    cloud = noise(321, 8, 8)
    nuance = noise(29, 24, 21)
    glow = 0
    metal = 0

    if name == "Bark":
        warped = U + 0.019 * np.sin(V * 6.283 * 2) + 0.10 * (noise(61, 8, 4) - 0.5)
        plate = noise(13, 22, 7, warped, V)
        split = remap(noise(11, 46, 4, warped, V), 0.55, 0.88)
        ridges = noise(22, 128, 20, warped, V)
        height = 0.59 * plate + 0.28 * ridges + 0.17 * grain - 0.42 * split
        color = palette(height + 0.12 * cloud, (27, 22, 20), (70, 53, 43), (124, 97, 72))
        lichen = remap(cloud * 0.55 + nuance * 0.33 + grain * 0.12, 0.57, 0.78) * 0.77
        color = mix(color, palette(nuance, (45, 49, 35), (92, 101, 69), (139, 145, 105)), lichen)
        rough = 0.88 + grain * 0.10
    elif name == "Endgrain":
        radius = np.hypot((U - 0.51) * 1.08, V - 0.46)
        angle = np.arctan2(V - 0.46, U - 0.51)
        rings = np.sin(radius * 193 + 3.9 * cloud + 1.6 * np.sin(3 * angle))
        crack = remap(np.cos(angle * 5 + noise(22, 10, 10) * 0.12), 0.98, 1) * remap(radius, 0.19, 0.63)
        height = 0.5 + 0.115 * rings + 0.09 * grain - 0.25 * crack
        color = palette(height + 0.30 * nuance - 0.36 * remap(radius, 0.41, 0.59),
                        (52, 35, 27), (134, 98, 62), (200, 158, 103))
        rough = 0.74 + grain * 0.16
    elif name == "Moss":
        pods = remap(noise(12, 64, 52), 0.28, 0.79)
        height = 0.38 * pods + 0.36 * cloud + 0.22 * grain
        color = palette(height, (28, 39, 30), (78, 96, 50), (135, 148, 74))
        rough = 0.83 + grain * 0.12
    elif name == "Fungus":
        gill = 0.5 + 0.5 * np.sin(U * np.pi * 2 * 40 + np.sin(V * 24) * 0.6)
        band = 0.5 + 0.5 * np.sin(V * 58 + nuance * 2.3)
        height = 0.50 * cloud + 0.22 * band + 0.07 * grain + 0.21 * gill * remap(V, 0.42, 0.80)
        cap = palette(height, (74, 35, 24), (157, 78, 34), (224, 157, 79))
        edge = palette(height, (88, 61, 39), (174, 140, 91), (233, 206, 150))
        color = mix(cap, edge, remap(V, 0.45, 0.57) * (1 - 0.2 * remap(V, 0.83, 1)))
        rough = 0.66 + grain * 0.22
    elif name in ("Slate", "Carving"):
        layers = noise(311, 12, 51, U, V + 0.12 * U + 0.04 * cloud)
        pits = remap(noise(171, 77, 86), 0.56, 0.86)
        seam = remap(noise(411, 13, 23), 0.70, 0.87)
        height = 0.40 * cloud + 0.21 * layers + 0.18 * nuance + 0.17 * grain - 0.24 * seam - 0.12 * pits
        tone = height + 0.16 * remap(layers, 0.43, 0.83)
        if name == "Carving":
            glyph = [
                ((0.49, 0.26), (0.50, 0.68)), ((0.50, 0.68), (0.58, 0.77)),
                ((0.50, 0.55), (0.34, 0.70)), ((0.49, 0.50), (0.66, 0.61)),
                ((0.34, 0.70), (0.30, 0.77)), ((0.66, 0.61), (0.72, 0.71)),
                ((0.49, 0.32), (0.38, 0.37)), ((0.49, 0.34), (0.60, 0.38)),
            ]
            border = [
                ((0.17, 0.17), (0.15, 0.71)), ((0.15, 0.71), (0.29, 0.85)),
                ((0.29, 0.85), (0.48, 0.92)), ((0.48, 0.92), (0.70, 0.85)),
                ((0.70, 0.85), (0.83, 0.73)), ((0.83, 0.73), (0.85, 0.22)),
                ((0.26, 0.19), (0.71, 0.19)),
            ]
            fracture = [
                ((1.01, 0.58), (0.79, 0.52)), ((0.79, 0.52), (0.72, 0.44)),
                ((0.72, 0.44), (0.56, 0.43)), ((0.79, 0.52), (0.72, 0.55)),
            ]
            cut = score(glyph, 0.022) + 0.56 * score(border, 0.013) + 0.75 * score(fracture, 0.010)
            weathered = cut * (0.61 + 0.39 * nuance)
            height -= 0.52 * weathered
            tone -= 0.67 * weathered
        color = palette(tone, (40, 48, 49), (99, 109, 107), (162, 168, 157))
        algae = remap(cloud * 0.6 + grain * 0.19 + pits * 0.18, 0.60, 0.77)
        color = mix(color, palette(nuance, (48, 57, 42), (92, 110, 74), (138, 148, 105)), algae * 0.82)
        rough = 0.68 + 0.27 * noise(235, 28, 29)
    elif name == "Iron":
        hammer = noise(72, 63, 59)
        rust = remap(cloud * 0.66 + hammer * 0.34, 0.49, 0.80)
        scratches = remap(noise(73, 129, 10), 0.72, 0.94)
        height = 0.48 * hammer + 0.15 * grain - 0.34 * scratches + 0.20 * rust
        steel = palette(0.18 + height + scratches * 0.68, (37, 42, 43), (104, 110, 110), (173, 176, 164))
        color = mix(steel, palette(nuance, (46, 28, 20), (116, 66, 38), (155, 100, 60)), rust)
        rough, metal = 0.37 + rust * 0.55, 0.91 - rust * 0.75
    elif name == "Amber":
        height = 0.34 * nuance + 0.17 * grain
        edge = remap(np.abs(U - 0.5) * 2, 0.56, 1.02)
        soot = remap(V + (cloud - 0.5) * 0.35, 0.58, 1.05)
        heat = (1 - edge * 0.68) * (1 - soot * 0.76) * (0.65 + 0.35 * cloud)
        color = palette(heat + 0.22 * nuance, (65, 31, 14), (208, 98, 29), (255, 208, 118))
        rough, glow = 0.32 + 0.32 * nuance, 0.22 + 0.78 * heat
    else:
        raise ValueError(name)

    dy, dx = np.gradient(height)
    normal = np.stack((-dx * 7, -dy * 7, np.ones_like(height)), -1)
    normal = normal / np.linalg.norm(normal, axis=-1, keepdims=True) * 0.5 + 0.5
    return {"Color": color, "Normal": normal, "Roughness": rough, "Metalness": metal, "Emissive": glow}


def uv(tile, u, v):
    index = next(tiles.index(tile) for tiles in ATLASES.values() if tile in tiles)
    x = index % 2 * SIZE + GUTTER + 0.5 + u * (INNER - 1)
    y = index // 2 * SIZE + GUTTER + 0.5 + v * (INNER - 1)
    return x / (SIZE * 2), y / (SIZE * 2)


def save_png(path, pixels):
    def chunk(name, data):
        return struct.pack(">I", len(data)) + name + data + struct.pack(">I", zlib.crc32(name + data))

    height, width = pixels.shape[:2]
    mode = 2 if pixels.ndim == 3 else 0
    header = struct.pack(">IIBBBBB", width, height, 8, mode, 0, 0, 0)
    rows = b"".join(b"\x00" + row.tobytes() for row in pixels[::-1])
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header)
                     + chunk(b"IDAT", zlib.compress(rows, 6)) + chunk(b"IEND", b""))


def write_textures(directory):
    directory.mkdir(exist_ok=True)
    for name, tiles in ATLASES.items():
        by_channel = [paint(tile) for tile in tiles]
        channels = ("Color", "Normal", "Roughness")
        if name == "Roadside":
            channels += ("Metalness", "Emissive")
        for channel in channels:
            shape = (SIZE * 2, SIZE * 2, 3) if channel in ("Color", "Normal") else (SIZE * 2, SIZE * 2)
            atlas = np.empty(shape, dtype=np.uint8)
            for index, tile in enumerate(by_channel):
                pixels = np.clip(np.round(np.asarray(tile[channel]) * 255), 0, 255).astype(np.uint8)
                x, y = index % 2 * SIZE, index // 2 * SIZE
                if pixels.ndim:
                    pad = ((GUTTER, GUTTER), (GUTTER, GUTTER))
                    pixels = np.pad(pixels, pad + ((0, 0),) * (pixels.ndim - 2), mode="edge")
                atlas[y:y + SIZE, x:x + SIZE] = pixels
            save_png(directory / f"{name}_{channel}.png", atlas)
