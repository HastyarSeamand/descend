"""Build, texture, light, and export the Cursed Woods trail props in Blender."""

import argparse
import json
import math
from pathlib import Path
import random
import sys

import bpy
from mathutils import Vector

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
sys.dont_write_bytecode = True
from woods_textures import ATLASES, uv, write_textures

TAU = math.tau


class Prop:
    def __init__(self, name, atlas):
        self.name = name
        self.atlas = atlas
        self.vertices = []
        self.faces = []
        self.uvs = []
        self.smooth = []
        self.rng = random.Random(name)

    def polygon(self, indices, tile, local_uv, smooth=False):
        if tile not in ATLASES[self.atlas]:
            raise ValueError(tile)
        self.faces.append(indices)
        self.uvs.append([uv(tile, u, v) for u, v in local_uv])
        self.smooth.append(smooth)

    def sweep(self, points, tile, *, sides=10, ridged=0.0, oval=1.0, caps=None, smooth=True):
        """Connect tapered cross-sections along the centerline and unwrap their length."""
        base = len(self.vertices)
        path = [Vector(p) for p, _ in points]
        distances = [0.0]
        for a, b in zip(path, path[1:]):
            distances.append(distances[-1] + (b - a).length)
        rib = [1 + self.rng.uniform(-ridged, ridged) for _ in range(sides)]
        tangent = (path[1] - path[0]).normalized()
        ref = Vector((0, 1, 0)) if abs(tangent.y) < 0.93 else Vector((1, 0, 0))
        axis = ref.cross(tangent).normalized()

        for index, (center, (_, radius)) in enumerate(zip(path, points)):
            tangent = (path[min(index + 1, len(path) - 1)] - path[max(0, index - 1)]).normalized()
            axis = (axis - tangent * axis.dot(tangent)).normalized()
            across = tangent.cross(axis)
            for j in range(sides):
                angle = TAU * j / sides
                scale = rib[j] + self.rng.uniform(-0.32, 0.32) * ridged
                outline = axis * math.cos(angle) + across * (oval * math.sin(angle))
                jitter = tangent * self.rng.uniform(-ridged, ridged) * radius * 0.32
                self.vertices.append(tuple(center + outline * (radius * scale) + jitter))

        maximum = distances[-1]
        for ring in range(len(path) - 1):
            bottom = base + ring * sides
            top = bottom + sides
            v0, v1 = distances[ring] / maximum, distances[ring + 1] / maximum
            for j in range(sides):
                k = (j + 1) % sides
                u0, u1 = j / sides, (j + 1) / sides
                self.polygon((bottom+j, bottom+k, top+k, top+j), tile,
                             [(u0, v0), (u1, v0), (u1, v1), (u0, v1)], smooth)

        disk = [(0.5 + 0.49 * math.cos(TAU*j/sides), 0.5 + 0.49 * math.sin(TAU*j/sides))
                for j in range(sides)]
        a, b = caps if caps else (tile, tile)
        self.polygon(tuple(reversed(range(base, base+sides))), a, disk[::-1])
        last = base + (len(path)-1) * sides
        self.polygon(tuple(range(last, last+sides)), b, disk)

    def stone(self, silhouette, depth, *, lean=0.0, front="Slate", bevel=0.13):
        """Shape a thin hewn slab around an irregular, counterclockwise X/Z outline."""
        first = len(self.vertices)
        sides = len(silhouette)
        xs, zs = zip(*silhouette)
        center_x, center_z = sum(xs)/sides, sum(zs)/sides
        width, height = max(xs)-min(xs), max(zs)-min(zs)
        d = min(depth * .4, bevel * 0.8)
        shifts = [self.rng.uniform(-0.035, 0.035) for _ in range(sides)]
        for y, border in [(-depth/2, bevel), (-depth/2+d, 0), (depth/2-d, 0), (depth/2, bevel * 0.7)]:
            for j, (x, z) in enumerate(silhouette):
                self.vertices.append((x + (center_x-x)*border,
                                      y + (z-center_z)*lean + shifts[j],
                                      z + (center_z-z)*border * 0.5))
        face_uv = [((x-min(xs))/width, (z-min(zs))/height) for x, z in silhouette]
        self.polygon(tuple(range(first, first+sides)), front, face_uv)
        last = first + 3*sides
        self.polygon(tuple(reversed(range(last, last+sides))), "Slate", face_uv[::-1])
        for ring in range(3):
            a = first + ring*sides
            b = a + sides
            for j in range(sides):
                k = (j + 1) % sides
                self.polygon((a+k, a+j, b+j, b+k), "Slate",
                             [(0.82, 0.32), (0.17, 0.32), (0.17, 0.53), (0.82, 0.53)])

    def torus(self, center, radius, thickness, *, plane="XZ", points=14, stretch=1.0):
        first = len(self.vertices)
        c = Vector(center)
        across = Vector((1, 0, 0)) if plane == "XZ" else Vector((0, 1, 0))
        up = Vector((0, 0, 1))
        normal = across.cross(up)
        for j in range(points):
            t = TAU * j / points
            radial = across * math.cos(t) + up * math.sin(t)
            ring = c + radius * (across * math.cos(t) + up * math.sin(t) * stretch)
            for k in range(5):
                phi = TAU*k/5
                self.vertices.append(tuple(ring + thickness*(radial*math.cos(phi) + normal*math.sin(phi))))
        for j in range(points):
            for k in range(5):
                a, b = first+j*5, first+((j+1) % points)*5
                kn = (k+1) % 5
                self.polygon((a+k, b+k, b+kn, a+kn), "Iron",
                             [(j/points,k/5), ((j+1)/points,k/5),
                              ((j+1)/points,(k+1)/5), (j/points,(k+1)/5)], True)

    def moss(self, center, dims, tilt=0.0):
        x, y, z = center
        sx, sy, sz = dims
        self.sweep([((x-tilt*.35,y,z-sz*.57), sx*.62),
                    ((x,y,z), sx), ((x+tilt,y,z+sz*.72), sx*.72),
                    ((x+tilt*1.14,y,z+sz), sx*.24)],
                   "Moss", sides=8, oval=sy/sx, ridged=.29)

    def mesh(self, material, collection):
        mesh = bpy.data.meshes.new(self.name)
        mesh.from_pydata(self.vertices, [], self.faces)
        if mesh.validate():
            raise RuntimeError(f"Invalid geometry in {self.name}")
        mesh.update()
        uvs = mesh.uv_layers.new(name="UVMap")
        for polygon, coords, smooth in zip(mesh.polygons, self.uvs, self.smooth):
            polygon.use_smooth = smooth
            for loop, coord in zip(polygon.loop_indices, coords):
                uvs.data[loop].uv = coord
        mesh.materials.append(material)
        obj = bpy.data.objects.new(self.name, mesh)
        collection.objects.link(obj)
        return obj


def deadwood():
    prop = Prop("Split Deadwood", "Deadwood")
    sweep = prop.sweep
    sweep([((.04,0,.01), 1.47), ((.06,-.06,.65), 1.34),
           ((.19,-.15,1.65), .98), ((.45,.04,3.18), .82),
           ((.67,.26,5.08), .72), ((.46,.48,6.64), .60), ((.39,.47,8.18), .42),
           ((.78,.25,9.42), .32), ((.97,.10,10.30), .25),
           ((1.24,.12,10.80), .105)], "Bark", sides=16,
          ridged=.23, oval=.83, caps=("Bark","Endgrain"))
    sweep([((.49,.29,4.52), .46), ((.17,.29,5.53), .59),
           ((-.67,.22,6.36), .53), ((-1.71,.03,7.67), .42),
           ((-2.27,-.36,9.30), .30), ((-2.38,-.58,10.72), .21),
           ((-2.77,-.57,11.79), .10), ((-2.55,-.63,12.46), .025)],
          "Bark", sides=11, ridged=.23)
    branches = [
        [((.55,.17,4.75),.40), ((1.77,-.23,5.47),.33), ((2.76,-.72,5.52),.23),
         ((3.60,-1.07,6.25),.17), ((4.46,-1.22,6.48),.087), ((5.10,-1.59,7.25),.014)],
        [((2.52,-.59,5.55),.15), ((3.04,-.46,6.55),.087), ((3.01,-.61,7.39),.018)],
        [((3.89,-1.10,6.33),.085), ((4.74,-.69,6.11),.045), ((5.22,-.66,6.27),.018)],
        [((-.88,.15,6.66),.30), ((-2.78,.61,6.65),.19), ((-3.76,.61,7.05),.13),
         ((-4.62,.30,7.09),.07), ((-5.09,-.02,7.54),.02)],
        [((-3.62,.60,7.02),.09), ((-4.04,1.04,7.60),.055), ((-4.15,1.43,8.08),.017)],
        [((-2.29,-.37,9.55),.21), ((-3.15,-.56,9.95),.14),
         ((-3.57,-.40,10.71),.08), ((-4.21,-.48,11.13),.018)],
        [((.55,.46,7.33),.27), ((.25,1.64,7.97),.20), ((.63,2.62,8.57),.12),
         ((1.18,3.03,9.37),.035)],
        [((.84,.23,9.60),.19), ((1.74,-.04,10.24),.16), ((2.56,.36,10.95),.07),
         ((3.18,.52,11.08),.02)],
        [((.13,-.32,2.46),.22), ((-.16,-.88,3.16),.15), ((-.43,-1.03,3.47),.105)],
    ]
    for branch in branches:
        sweep(branch, "Bark", sides=8, ridged=.17, caps=("Bark", "Endgrain"))
    for index in range(7):
        a = index * TAU/7 + prop.rng.uniform(-.22,.22)
        direction = Vector((math.cos(a), math.sin(a), 0))
        side = Vector((-direction.y,direction.x,0))
        length = prop.rng.uniform(2.30,3.35)
        offset = prop.rng.uniform(-.70,.70)
        path = []
        for ratio, z, r, shift in [(0.12,1.16,.64,0), (.38,.65,.55,0), (.59,.30,.35,1),
                                   (.84,.18,.21,.6), (1,.07,.038,2)]:
            path.append((tuple(direction*(length*ratio) + side*(offset*shift) + Vector((0,0,z))),r))
        sweep(path, "Bark", sides=8, ridged=.22, oval=.77)
    for x, y, z, r in [(-.72,-.87,.42,.42),(.35,-1.19,.20,.68),(1.04,-.71,.72,.36),
                        (1.41,.84,.24,.48),(-1.20,.62,.30,.48),(-1.76,-.96,.18,.33)]:
        prop.moss((x,y,z), (r,r*.76,r*.36))
    for x, y, z, radius in [(-.34,-.83,2.27,.32),(-.50,-.78,1.99,.40),(-.64,-.81,1.66,.28)]:
        bracket(prop, (x,y,z), radius)
    return prop


def grave():
    prop = Prop("Wayfarer Grave", "Roadside")
    prop.stone([(-1.95,.04),(1.90,.04),(2.00,.22),(1.55,.55),(-1.70,.51),(-2.06,.29)],
               1.46, bevel=.13)
    prop.stone([(-1.40,.36),(1.34,.36),(1.36,.72),(1.05,.91),(-1.10,.94),(-1.43,.72)],
               1.13, bevel=.14)
    prop.stone([(-1.02,.59),(.92,.56),(1.10,1.37),(.93,2.33),(.97,2.61),(.78,2.72),
                (.78,2.99),(.56,3.32),(.18,3.57),(-.14,3.76),(-.53,3.55),(-.84,3.19),
                (-1.05,2.93),(-1.14,2.28),(-.99,1.87),(-1.15,1.72)],
               .66, front="Carving", lean=.17, bevel=.19)
    for x,y,z,sx,sy,sz in [(-1.62,-.76,.21,.38,.32,.22),(1.25,-.76,.16,.40,.24,.24),
                            (1.98,-.15,.19,.35,.39,.28),(-1.42,.61,.19,.42,.22,.31),
                            (.91,-1.07,.12,.21,.14,.13)]:
        prop.sweep([((x,y,.015),sx*.81),((x-.13*sz,y,z),sx),
                    ((x+.31*sz,y,z+sz),sx*.58)], "Slate", sides=7, oval=sy/sx,
                   ridged=.27, smooth=False)
    return prop


def lantern():
    prop = Prop("Grave Lantern", "Roadside")
    sweep = prop.sweep
    # Chipped stone pedestal, bolted ribs, and the bent iron hanger.
    sweep([((0,0,.015),.71),((0,0,.16),.83),((.02,0,.44),.68),
           ((.02,.01,.49),.53),((.04,.01,.75),.52),((.04,.01,.83),.46)],
          "Slate", sides=8, ridged=.12, smooth=False)
    sweep([((.04,.01,.64),.27),((.08,0,1.95),.18),((.09,.01,3.58),.151),
           ((.16,.02,5.28),.145),((.25,.02,6.13),.19),((.27,.02,6.32),.075)],
          "Iron", sides=8)
    for z, r in [(1.02,.32),(1.24,.285),(3.19,.202),(4.94,.196)]:
        sweep([((.04+.022*z,0,z-.05),r*.81),((.04+.022*z,0,z),r),
               ((.04+.022*z,0,z+.065),r*.83)], "Iron", sides=8)
    sweep([((.19,.02,5.35),.155),((.52,.02,5.97),.148),((1.05,.01,6.24),.14),
           ((1.63,0,6.20),.126),((1.95,0,5.96),.11),((2.01,0,5.65),.085),
           ((1.87,0,5.47),.065),((1.71,0,5.52),.038)], "Iron", sides=8)
    sweep([((.11,.02,5.05),.083),((.52,.02,5.24),.086),((.92,.02,5.59),.075),
           ((1.38,.02,6.14),.069)], "Iron", sides=7)
    sweep([((.19,.04,5.84),.086),((-.24,.04,6.04),.080),((-.55,.04,6.40),.055),
           ((-.53,.04,6.66),.027)], "Iron", sides=7)
    for index in range(3):
        prop.torus((1.87,0,5.51-.19*index), .104, .031,
                   plane="XZ" if index % 2 else "YZ", stretch=1.27)
    x = 1.87
    sweep([((x,0,3.26),.095),((x,0,3.44),.19),((x,0,3.51),.47),
           ((x,0,3.64),.64),((x,0,3.74),.65),((x,0,3.84),.54)],
          "Iron", sides=8, smooth=False)
    sweep([((x,0,4.73),.57),((x,0,4.83),.73),((x,0,4.94),.71),
           ((x,0,5.20),.37),((x,0,5.29),.13)], "Iron", sides=8, smooth=False)
    # One full amber texture tile per pane, hemmed in by forged metal ribs.
    first = len(prop.vertices)
    for z, r in [(3.73,.48),(3.91,.54),(4.54,.58),(4.76,.51)]:
        for j in range(8):
            a = TAU*j/8
            prop.vertices.append((x+r*math.cos(a),r*math.sin(a),z))
    for ring, v0, v1 in [(0,0,.17),(1,.17,.78),(2,.78,1)]:
        a, b = first+ring*8, first+(ring+1)*8
        for j in range(8):
            k = (j+1) % 8
            prop.polygon((a+j,a+k,b+k,b+j), "Amber", [(0,v0),(1,v0),(1,v1),(0,v1)])
    # Hidden pane caps close the shell.
    for indices in [tuple(reversed(range(first,first+8))),tuple(range(first+24,first+32))]:
        prop.polygon(indices, "Amber", [(.5+.48*math.cos(TAU*j/8),.5+.48*math.sin(TAU*j/8)) for j in range(8)])
    for j in range(8):
        a = TAU*j/8
        sweep([((x+r*math.cos(a),r*math.sin(a),z),thickness)
               for r,z,thickness in [(.52,3.68,.047),(.57,3.91,.043),
                                     (.62,4.51,.040),(.53,4.79,.053)]],
              "Iron", sides=5)
        if j % 2 == 0:
            a += TAU/16
            sweep([((x + r*math.cos(a), r*math.sin(a), z), thickness)
                   for r,z,thickness in [(.43,3.74,.071),(.52,3.97,.053),(.54,4.15,.014)]],
                  "Iron", sides=5)
    return prop


def bracket(prop, center, radius):
    x, y, z = center
    prop.sweep([((x,y-.47*radius,z-.17*radius), radius*.49),
                ((x,y-.62*radius,z), radius),
                ((x,y-.46*radius,z+.17*radius), radius*.90),
                ((x,y-.14*radius,z+.24*radius), radius*.35)],
               "Fungus", sides=11, oval=.53, ridged=.17)


def toadstool(prop, x, y, z, height, radius, lean):
    dx, dy = lean
    prop.sweep([((x,y,z),radius*.22),((x+.55*dx,y+.55*dy,z+height*.5),radius*.17),
                ((x+dx,y+dy,z+height),radius*.11)], "Endgrain",
               sides=6, ridged=.11)
    x, y, z = x+dx, y+dy, z+height
    # Cap mapped crown-to-gills so the pale bands stay under the lip.
    prop.sweep([((x,y,z+.34*radius),radius*.12),
                ((x,y,z+.29*radius),radius*.51),((x+.05*radius,y,z+.12*radius),radius*.87),
                ((x+.09*radius,y,z-.08*radius),radius),((x+.06*radius,y,z-.19*radius),radius*.85),
                ((x,y,z-.23*radius),radius*.16)], "Fungus",
               sides=12, oval=.89, ridged=.13)


def fallen_log():
    prop = Prop("Witchcap Log", "Deadwood")
    prop.sweep([((-2.67,-.69,.58),.43),((-2.35,-.42,.62),.64),
                ((-1.52,-.10,.69),.67),((-.55,.07,.74),.74),((.54,.20,.81),.71),
                ((1.56,.25,.80),.79),((2.49,.36,.75),.81),((2.64,.36,.76),.74)],
               "Bark", sides=18, ridged=.17, oval=.88, caps=("Endgrain","Endgrain"))
    for points in [
        [((-1.68,-.30,.84),.32),((-2.04,-.79,1.11),.27),((-2.16,-1.08,1.63),.15),
         ((-2.61,-1.43,1.85),.085)],
        [((-.40,.50,.56),.34),((-.80,1.02,.44),.23),((-.72,1.72,.33),.13),((-.22,2.01,.17),.036)],
        [((1.31,-.29,.38),.41),((1.77,-.74,.38),.29),((2.34,-1.01,.20),.175),
         ((2.74,-1.24,.14),.028)],
        [((.22,-.22,1.13),.23),((.34,-.68,1.38),.18),((.58,-.83,1.68),.14)],
    ]:
        prop.sweep(points, "Bark", sides=9, ridged=.18, caps=("Bark","Endgrain"))
    for x,y,z,r in [(-1.71,-.05,1.20,.49),(-1.17,.15,1.27,.49),(-.60,.22,1.32,.43),
                     (-.15,.22,1.37,.49),(.41,.29,1.37,.42),(1.96,.31,1.43,.49),
                     (2.29,.22,1.41,.36),(1.75,-.67,.23,.43),(-.61,1.27,.34,.30),
                     (-2.59,-.98,.18,.32),(-2.37,.11,.47,.32)]:
        prop.moss((x,y,z),(r,r*.70,r*.16), tilt=.018)
    for x,y,z,r in [(1.18,-.45,1.02,.43),(1.54,-.47,.84,.34),(.85,-.45,.67,.45),
                     (2.10,-.36,.56,.28),(-1.53,-.64,.93,.25)]:
        bracket(prop,(x,y,z),r)
    for settings in [(-.93,.03,1.46,.82,.47,(.11,-.18)),(-.47,.20,1.51,1.13,.56,(-.07,.06)),
                      (-.18,-.13,1.48,.58,.31,(.08,-.10)),(-1.47,.28,1.35,.50,.33,(-.15,.06)),
                      (1.76,.19,1.53,.46,.29,(.09,-.14)),(1.99,.50,1.56,.72,.36,(.14,.13)),
                      (2.26,.24,1.53,.35,.20,(.09,-.03)),(-2.49,-1.0,.12,.45,.25,(-.12,-.08)),
                      (-2.85,-.80,.07,.59,.34,(-.19,.06)),(-2.67,-1.25,.04,.26,.15,(.01,-.10))]:
        toadstool(prop,*settings)
    return prop


def atlas_material(name, textures):
    material = bpy.data.materials.new(f"Woods | {name}")
    material.diffuse_color = (0.20, 0.14, 0.09, 1) if name == "Deadwood" else (0.22, 0.24, 0.22, 1)
    material.use_nodes = True
    nodes = material.node_tree.nodes
    link = material.node_tree.links.new
    shader = nodes.get("Principled BSDF")
    shader.location = (320, 100)
    nodes.get("Material Output").location = (640, 100)
    export = {"Color": "Base Color", "Roughness": "Roughness", "Metalness": "Metallic"}
    for index, channel in enumerate(("Color","Roughness","Normal","Metalness","Emissive")):
        path = textures / f"{name}_{channel}.png"
        if not path.exists():
            continue
        texture = nodes.new("ShaderNodeTexImage")
        texture.label = channel
        texture.location = (-470, 370-index*245)
        texture.image = bpy.data.images.load(str(path), check_existing=True)
        if channel != "Color":
            texture.image.colorspace_settings.name = "Non-Color"
        if channel in export:
            link(texture.outputs["Color"], shader.inputs[export[channel]])
        if channel == "Normal":
            normal = nodes.new("ShaderNodeNormalMap")
            normal.location = (50, -150)
            normal.inputs["Strength"].default_value = 1.0
            link(texture.outputs["Color"], normal.inputs["Color"])
            link(normal.outputs["Normal"], shader.inputs["Normal"])
        if channel == "Emissive":
            link(texture.outputs["Color"], shader.inputs["Emission Strength"])
            shader.inputs["Emission Color"].default_value = (2.3, .56, .085, 1)
    nodes.active = next(node for node in nodes if node.label == "Color")
    return material


def area(collection, name, position, aim, power, color, size):
    light = bpy.data.lights.new(name, "AREA")
    light.color, light.energy, light.shape, light.size = color, power, "DISK", size
    obj = bpy.data.objects.new(name, light)
    collection.objects.link(obj)
    obj.location = position
    obj.rotation_euler = (Vector(aim) - obj.location).to_track_quat("-Z","Y").to_euler()
    return obj


def make_stage(collection):
    ground = bpy.data.meshes.new("Preview Floor")
    ground.from_pydata([(-70,-55,.013),(70,-55,.013),(70,55,.013),(-70,55,.013)], [], [(0,1,2,3)])
    floor = bpy.data.objects.new("Preview Floor", ground)
    collection.objects.link(floor)
    material = bpy.data.materials.new("Studio backdrop")
    material.use_nodes = True
    nodes = material.node_tree.nodes
    link = material.node_tree.links.new
    shader = nodes.get("Principled BSDF")
    shader.inputs["Roughness"].default_value = .86
    noise = nodes.new("ShaderNodeTexNoise")
    coordinate = nodes.new("ShaderNodeTexCoord")
    link(coordinate.outputs["Object"], noise.inputs["Vector"])
    noise.inputs["Scale"].default_value = 2.8
    noise.inputs["Detail"].default_value = 4
    ramp = nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].color = (.008,.011,.012,1)
    ramp.color_ramp.elements[1].color = (.019,.026,.025,1)
    link(noise.outputs["Fac"], ramp.inputs["Fac"])
    link(ramp.outputs["Color"], shader.inputs["Base Color"])
    bump = nodes.new("ShaderNodeBump")
    bump.inputs["Strength"].default_value = .11
    bump.inputs["Distance"].default_value = .07
    link(noise.outputs["Fac"], bump.inputs["Height"])
    link(bump.outputs["Normal"], shader.inputs["Normal"])
    ground.materials.append(material)

    cam = bpy.data.objects.new("Prop Camera", bpy.data.cameras.new("Prop Camera"))
    collection.objects.link(cam)
    cam.data.type = "ORTHO"
    return cam


def frame_camera(camera, models, direction, aspect, margin):
    vertices = [obj.matrix_world @ v.co for obj in models for v in obj.data.vertices]
    rotation = (-Vector(direction)).to_track_quat("-Z","Y")
    projected = [rotation.inverted() @ vertex for vertex in vertices]
    lo = Vector(tuple(min(v[axis] for v in projected) for axis in range(3)))
    hi = Vector(tuple(max(v[axis] for v in projected) for axis in range(3)))
    center = rotation @ ((lo + hi) * 0.5)
    camera.location = center + Vector(direction).normalized() * 32
    camera.rotation_euler = rotation.to_euler()
    camera.data.ortho_scale = max(hi.x - lo.x, (hi.y - lo.y) * aspect) * margin
    return center


def show_lighting(collection, center, span, lantern_position):
    area(collection,"Warm key",center + Vector((-.62,-.77,.89))*span,center,
         41 * span**2,(1.0,.78,.58),span*.71)
    area(collection,"Blue fill",center + Vector((.72,-.42,.47))*span,center,
         14 * span**2,(.37,.63,1.0),span*.85)
    area(collection,"Forest rim",center + Vector((.08,.84,.72))*span,center,
         53 * span**2,(.41,1.0,.79),span*.61)
    if lantern_position is not None:
        data = bpy.data.lights.new("Amber spill preview", "POINT")
        data.color, data.energy, data.shadow_soft_size = (1.0,.37,.075), 17, .44
        obj = bpy.data.objects.new(data.name, data)
        collection.objects.link(obj)
        obj.location = lantern_position


def clear_lighting(collection):
    for obj in list(collection.objects):
        if obj.type == "LIGHT":
            data = obj.data
            bpy.data.objects.remove(obj, do_unlink=True)
            bpy.data.lights.remove(data)


def export_props(models, destination):
    destination.mkdir(exist_ok=True)
    sizes = []
    for model in models:
        bpy.ops.object.select_all(action="DESELECT")
        model.select_set(True)
        bpy.context.view_layer.objects.active = model
        model.data.calc_loop_triangles()
        stem = model.name.replace(" ", "_")
        path = destination / f"{stem}.fbx"
        bpy.ops.export_scene.fbx(
            filepath=str(path), use_selection=True, object_types={"MESH"},
            axis_forward="-Z", axis_up="Y", apply_scale_options="FBX_SCALE_NONE",
            apply_unit_scale=False, use_triangles=True, use_tspace=True,
            mesh_smooth_type="OFF", bake_anim=False, path_mode="RELATIVE",
        )
        bounds = model.bound_box
        sizes.append({
            "file": path.name,
            "triangles": len(model.data.loop_triangles),
            "local_size_xyz": [round(max(v[axis] for v in bounds) - min(v[axis] for v in bounds), 3)
                               for axis in range(3)],
            "atlas": model["Atlas"],
        })
    (destination / "manifest.json").write_text(json.dumps(sizes, indent=2)+"\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--preview", action="store_true", help="Render four material close-ups")
    args = parser.parse_args(sys.argv[sys.argv.index("--")+1:] if "--" in sys.argv else [])
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.unit_settings.system = "NONE"
    scene.render.engine = "CYCLES"
    scene.cycles.samples = 20
    scene.cycles.use_denoising = True
    scene.render.image_settings.file_format = "PNG"
    scene.render.image_settings.color_mode = "RGB"
    scene.view_settings.view_transform = "AgX"
    scene.world = bpy.data.worlds.new("Cool sky")
    scene.world.use_nodes = True
    scene.world.node_tree.nodes["Background"].inputs["Color"].default_value = (.15,.22,.27,1)
    scene.world.node_tree.nodes["Background"].inputs["Strength"].default_value = .37
    assets = bpy.data.collections.new("Cursed Woods Props")
    scene.collection.children.link(assets)
    studio = bpy.data.collections.new("Preview Stage")
    scene.collection.children.link(studio)

    textures = ROOT / "textures"
    write_textures(textures)
    materials = {name: atlas_material(name, textures) for name in ATLASES}
    props = [deadwood(), grave(), lantern(), fallen_log()]
    models = []
    for prop in props:
        model = prop.mesh(materials[prop.atlas], assets)
        model["Atlas"] = prop.atlas
        models.append(model)
    bpy.context.view_layer.update()
    export_props(models, ROOT / "fbx")

    camera = make_stage(studio)
    scene.camera = camera
    if args.preview:
        previews = ROOT / "previews"
        previews.mkdir(exist_ok=True)
        scene.render.resolution_x, scene.render.resolution_y = 800, 500
        angles = [(6,-18,7), (3,-15,5), (5,-16,4), (8,-14,8)]
        for model, angle in zip(models, angles):
            for other in models:
                other.hide_render = other != model
            clear_lighting(studio)
            center = frame_camera(camera,[model],angle,800/500,1.20)
            span = max(model.dimensions)
            lantern_position = (1.96,-.63,4.14) if model == models[2] else None
            show_lighting(studio,center,span,lantern_position)
            scene.render.filepath = str(previews / (model.name.replace(" ","_") + ".png"))
            bpy.ops.render.render(write_still=True)

    clear_lighting(studio)
    for model, position in zip(models,[(-9,0,0),(-1,-2,0),(4,0,0),(11,-.2,0)]):
        model.location = position
        model.hide_render = False
    bpy.context.view_layer.update()
    scene.render.resolution_x, scene.render.resolution_y = 1660, 820
    center = frame_camera(camera,models,(0,-23,7),1660/820,1.11)
    show_lighting(studio,center,23,(5.96,-.63,4.14))
    bpy.ops.object.select_all(action="DESELECT")
    for screen in bpy.data.screens:
        for area_view in screen.areas:
            if area_view.type == "VIEW_3D":
                view = area_view.spaces.active
                view.region_3d.view_location = center
                view.region_3d.view_distance = 29
                view.region_3d.view_rotation = camera.rotation_euler.to_quaternion()
                view.region_3d.view_perspective = "ORTHO"
                view.overlay.show_overlays = False
                view.shading.color_type = "TEXTURE"
    for img in bpy.data.images:
        if img.source == "FILE":
            img.pack()
    bpy.context.preferences.filepaths.save_version = 0
    scene.render.filepath = "//previews/Woods_Lineup.png"
    bpy.ops.wm.save_as_mainfile(filepath=str(ROOT / "Cursed Woods Props.blend"), compress=True)


if __name__ == "__main__":
    main()
