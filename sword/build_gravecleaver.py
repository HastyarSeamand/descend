"""
The Descent - Gravecleaver (first greatsword), built from concept v1.
Run headless:
  blender -b -P build_gravecleaver.py -- <out_dir>
Units: 1 Blender unit = 1 Roblox stud. Sword points up +Z, flat faces toward +Y/-Y,
cutting edge on +X, notched spine on -X. Grip bottom sits near Z=0.

Outputs in <out_dir>:
  Gravecleaver.blend      editable source (named parts)
  Gravecleaver.fbx        for Studio's 3D Importer (4 meshes: Blade, Fittings, Grip, CurseCrack)
  preview_front.png / preview_angle.png
"""
import bpy, bmesh, math, random, sys, os
from mathutils import Vector

argv = sys.argv
OUT = argv[argv.index("--") + 1] if "--" in argv else os.path.dirname(os.path.abspath(__file__))
os.makedirs(OUT, exist_ok=True)
random.seed(7)

# ---------- reset scene ----------
bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene

# ---------- materials ----------
def make_mat(name, color, metallic=0.0, rough=0.6, emit=None, emit_strength=0.0):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    bsdf = m.node_tree.nodes.get("Principled BSDF")
    bsdf.inputs["Base Color"].default_value = (*color, 1)
    bsdf.inputs["Metallic"].default_value = metallic
    bsdf.inputs["Roughness"].default_value = rough
    if emit:
        key = "Emission Color" if "Emission Color" in bsdf.inputs else "Emission"
        bsdf.inputs[key].default_value = (*emit, 1)
        bsdf.inputs["Emission Strength"].default_value = emit_strength
    m.diffuse_color = (*(emit or color), 1)
    return m

M_IRON   = make_mat("Iron",      (0.20, 0.20, 0.21), 0.85, 0.55)
M_DARK   = make_mat("DarkIron",  (0.07, 0.07, 0.075), 0.9, 0.5)
M_CLOTH  = make_mat("RedCloth",  (0.30, 0.05, 0.05), 0.0, 0.9)
M_CHAR   = make_mat("CrackRim",  (0.03, 0.02, 0.02), 0.0, 0.9)
M_GLOW   = make_mat("CurseGlow", (0.9, 0.12, 0.04), 0.0, 0.4, emit=(1.0, 0.15, 0.04), emit_strength=6.0)

def assign(obj, mat):
    obj.data.materials.clear()
    obj.data.materials.append(mat)

def apply_all(obj):
    bpy.context.view_layer.objects.active = obj
    for o in bpy.context.selected_objects:
        o.select_set(False)
    obj.select_set(True)
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)

def join(objs, name):
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.object.join()
    ob = bpy.context.view_layer.objects.active
    ob.name = name
    ob.data.name = name
    return ob

def box(name, cx, cy, cz, sx, sy, sz, mat):
    bpy.ops.mesh.primitive_cube_add(size=1, location=(cx, cy, cz))
    o = bpy.context.active_object
    o.name = name
    o.scale = (sx, sy, sz)
    apply_all(o)
    assign(o, mat)
    return o

# ---------- BLADE: cleaver slab ----------
BLADE_Z0, BLADE_Z1 = 2.15, 6.2
T = 0.16          # half thickness at spine / flat
BEVEL = 0.24      # width of the sharpened bevel along the edge

def spine_x(z):  # spine (back) flares outward slightly toward the top
    return -0.50 - 0.18 * (z - BLADE_Z0) / (BLADE_Z1 - BLADE_Z0)

def edge_x(z):   # cutting edge flares out more -> blade widens toward tip
    return 0.50 + 0.35 * (z - BLADE_Z0) / (BLADE_Z1 - BLADE_Z0)

rows = []  # (spine_x, spine_z, edge_x, edge_z)
NOTCH_ZONE = (4.30, 5.20)
z = BLADE_Z0
while z < BLADE_Z1 - 1e-6:
    if not (NOTCH_ZONE[0] <= z <= NOTCH_ZONE[1]):
        chip = -random.uniform(0.0, 0.03) if (z > BLADE_Z0 + 0.3 and random.random() < 0.5) else 0.0
        rows.append((spine_x(z), z, edge_x(z) + chip, z))
    z += 0.2
# three sawtooth notches on the spine: slope out, then hard step back in
for z0 in (4.30, 4.60, 4.90):
    rows.append((spine_x(z0), z0, edge_x(z0), z0))
    rows.append((spine_x(z0 + 0.29) - 0.17, z0 + 0.29, edge_x(z0 + 0.29), z0 + 0.29))
    rows.append((spine_x(z0 + 0.30), z0 + 0.30, edge_x(z0 + 0.30), z0 + 0.30))
rows.append((spine_x(BLADE_Z1), BLADE_Z1, edge_x(BLADE_Z1), BLADE_Z1))
rows.sort(key=lambda r: r[1])
# blunt diagonal cleaver tip: the notched spine rises to the high point, the cut slopes down to the edge
rows.append((-0.74, 7.20, 0.90, 6.50))

bm = bmesh.new()
loops = []
for sx, sz, ex, ez in rows:
    bx = ex - BEVEL
    bz = sz + (ez - sz) * ((bx - sx) / (ex - sx))
    loop = [
        bm.verts.new((sx,  T, sz)),
        bm.verts.new((bx,  T, bz)),
        bm.verts.new((ex,  0, ez)),
        bm.verts.new((bx, -T, bz)),
        bm.verts.new((sx, -T, sz)),
    ]
    loops.append(loop)
for a, b in zip(loops, loops[1:]):
    n = len(a)
    for i in range(n):
        j = (i + 1) % n
        bm.faces.new((a[i], a[j], b[j], b[i]))
bm.faces.new(list(reversed(loops[0])))
bm.faces.new(loops[-1])
bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=0.0005)
bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
me = bpy.data.meshes.new("Blade")
bm.to_mesh(me)
bm.free()
blade = bpy.data.objects.new("Blade", me)
scene.collection.objects.link(blade)
assign(blade, M_IRON)

# ---------- CURSE CRACK (glowing seam on both faces) ----------
crack_main = [(-0.25, 3.2), (-0.05, 3.6), (-0.20, 4.0), (0.05, 4.4), (-0.10, 4.8), (0.15, 5.3), (0.00, 5.75)]
crack_branches = [
    [(-0.05, 3.6), (0.25, 3.78)],
    [(0.05, 4.4), (-0.30, 4.58)],
    [(0.15, 5.3), (0.40, 5.18)],
    [(-0.10, 4.8), (0.18, 4.95)],
]

def strip(points, width, y, name, mat):
    bm = bmesh.new()
    sign = 1 if y > 0 else -1
    prev = None
    for k, (x, zz) in enumerate(points):
        if k < len(points) - 1:
            dx, dz = points[k + 1][0] - x, points[k + 1][1] - zz
        else:
            dx, dz = x - points[k - 1][0], zz - points[k - 1][1]
        L = math.hypot(dx, dz) or 1
        nx, nz = -dz / L * width / 2, dx / L * width / 2
        taper = 0.35 if k in (0, len(points) - 1) else 1.0
        a = bm.verts.new((x + nx * taper, y, zz + nz * taper))
        b = bm.verts.new((x - nx * taper, y, zz - nz * taper))
        if prev:
            f = bm.faces.new((prev[0], prev[1], b, a))
            f.normal_update()
            if f.normal.y * sign < 0:
                f.normal_flip()
        prev = (a, b)
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    o = bpy.data.objects.new(name, me)
    scene.collection.objects.link(o)
    assign(o, mat)
    return o

rim_parts, glow_parts = [], []
for side in (1, -1):
    for i, pts in enumerate([crack_main] + crack_branches):
        w = 0.10 if i == 0 else 0.06
        rim_parts.append(strip(pts, w, side * (T + 0.002), f"rim{side}{i}", M_CHAR))
        glow_parts.append(strip(pts, w * 0.4, side * (T + 0.004), f"glow{side}{i}", M_GLOW))

# ---------- FITTINGS: band, lock plate, shackle + chain, crossguard, pommel ----------
fit = []
bz = 2.45
fit.append(box("Band", (spine_x(bz) + edge_x(bz)) / 2, 0, bz, (edge_x(bz) - spine_x(bz)) + 0.10, 2 * T + 0.08, 0.30, M_DARK))
fit.append(box("LockPlate", 0.28, -(T + 0.06), bz, 0.26, 0.06, 0.26, M_DARK))

def torus(name, loc, rot, R, r, mat):
    bpy.ops.mesh.primitive_torus_add(major_radius=R, minor_radius=r, major_segments=12, minor_segments=6,
                                     location=loc, rotation=rot)
    o = bpy.context.active_object
    o.name = name
    apply_all(o)
    assign(o, mat)
    return o

# chain hangs off the lock plate on the -Y face (the face the previews show)
cy = -(T + 0.14)
fit.append(torus("Shackle", (0.28, cy, 2.22), (0, math.radians(90), math.radians(90)), 0.13, 0.04, M_DARK))
for i, zz in enumerate((2.02, 1.84, 1.66, 1.48)):
    rot = (0, math.radians(90), 0) if i % 2 == 0 else (math.radians(90), 0, math.radians(90))
    fit.append(torus(f"Link{i}", (0.28 + 0.015 * i, cy, zz), rot, 0.10, 0.032, M_DARK))

# crossguard: thick bar, one end hooks up, the other hooks down (S shape)
fit.append(box("GuardBar", 0, 0, 2.05, 1.50, 0.36, 0.20, M_DARK))
fit.append(box("HookUp", 0.70, 0, 2.30, 0.12, 0.26, 0.40, M_DARK))
fit.append(box("HookDown", -0.70, 0, 1.80, 0.12, 0.26, 0.40, M_DARK))

def cone(name, loc, rot, r, depth, mat):
    bpy.ops.mesh.primitive_cone_add(vertices=8, radius1=r, radius2=0, depth=depth, location=loc, rotation=rot)
    o = bpy.context.active_object
    o.name = name
    apply_all(o)
    assign(o, mat)
    return o

fit.append(cone("SpikeUp", (0.62, 0, 2.55), (0, math.radians(-35), 0), 0.08, 0.28, M_DARK))
fit.append(cone("SpikeDown", (-0.62, 0, 1.55), (0, math.radians(180 - 35), 0), 0.08, 0.28, M_DARK))

# pommel collar + ring
bpy.ops.mesh.primitive_cylinder_add(vertices=10, radius=0.15, depth=0.14, location=(0, 0, 0.36))
collar = bpy.context.active_object
collar.name = "Collar"
apply_all(collar)
assign(collar, M_DARK)
fit.append(collar)
fit.append(torus("PommelRing", (0, 0, 0.10), (math.radians(90), 0, 0), 0.20, 0.065, M_DARK))

# ---------- GRIP: core + cloth wraps ----------
grip_parts = []
bpy.ops.mesh.primitive_cylinder_add(vertices=10, radius=0.10, depth=1.52, location=(0, 0, 1.19))
core = bpy.context.active_object
core.name = "GripCore"
apply_all(core)
assign(core, M_CLOTH)
grip_parts.append(core)
zz, k = 0.48, 0
while zz < 1.92:
    tilt = math.radians(12 if k % 2 == 0 else -12)
    grip_parts.append(torus(f"Wrap{k}", (0, 0, zz), (tilt, 0, 0), 0.105, 0.03, M_CLOTH))
    zz += 0.085
    k += 1

# ---------- join into 4 meshes ----------
fittings = join(fit, "Fittings")
grip = join(grip_parts, "Grip")
crack_rim = join(rim_parts, "CrackRim")
blade = join([blade, crack_rim], "Blade")   # dark rim lives on the blade mesh
crack = join(glow_parts, "CurseCrack")      # glow kept separate so the game can pulse it with the Curse

for o in (blade, fittings, grip, crack):
    bpy.context.view_layer.objects.active = o
    bpy.ops.object.select_all(action="DESELECT")
    o.select_set(True)
    bpy.ops.object.mode_set(mode="EDIT")
    bpy.ops.mesh.select_all(action="SELECT")
    bpy.ops.uv.smart_project(angle_limit=math.radians(66), island_margin=0.02)
    bpy.ops.object.mode_set(mode="OBJECT")
    bpy.ops.object.shade_flat()

root = bpy.data.objects.new("Gravecleaver", None)
scene.collection.objects.link(root)
for o in (blade, fittings, grip, crack):
    o.parent = root

tris = sum(sum(len(p.vertices) - 2 for p in o.data.polygons) for o in (blade, fittings, grip, crack))
print(f"[gravecleaver] triangles: {tris}")

# ---------- save + export ----------
bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT, "Gravecleaver.blend"))
bpy.ops.object.select_all(action="SELECT")
bpy.ops.export_scene.fbx(
    filepath=os.path.join(OUT, "Gravecleaver.fbx"),
    use_selection=True, apply_unit_scale=True, global_scale=1.0,
    axis_forward="-Z", axis_up="Y", mesh_smooth_type="FACE", add_leaf_bones=False,
    bake_space_transform=True,
)

# ---------- preview renders ----------
scene.render.engine = "BLENDER_WORKBENCH"
shading = scene.display.shading
shading.light = "STUDIO"
shading.color_type = "MATERIAL"
shading.show_cavity = True
shading.show_shadows = True
scene.render.resolution_x, scene.render.resolution_y = 1280, 720
world = bpy.data.worlds.new("W")
scene.world = world
world.color = (0.05, 0.06, 0.08)
scene.render.film_transparent = False

cam_data = bpy.data.cameras.new("Cam")
cam_data.type = "ORTHO"
cam = bpy.data.objects.new("Cam", cam_data)
scene.collection.objects.link(cam)
scene.camera = cam

def look(cam, pos, target):
    cam.location = pos
    d = Vector(target) - Vector(pos)
    cam.rotation_euler = d.to_track_quat("-Z", "Y").to_euler()

# lay the sword diagonally in frame like the concept
# camera on -Y so +X is screen-right; +62deg about Y puts the tip up-right and the notched spine on top
root.rotation_euler = (0, math.radians(62), 0)
bpy.context.view_layer.update()
th = math.radians(62)
center = (3.6 * math.sin(th), 0, 3.6 * math.cos(th))  # rotated midpoint of the sword
cam_data.ortho_scale = 8.2
look(cam, (center[0], -20, center[2]), center)
scene.render.filepath = os.path.join(OUT, "preview_front.png")
bpy.ops.render.render(write_still=True)

look(cam, (center[0] + 8, -14, center[2] + 7), center)
scene.render.filepath = os.path.join(OUT, "preview_angle.png")
bpy.ops.render.render(write_still=True)
print("[gravecleaver] done ->", OUT)
