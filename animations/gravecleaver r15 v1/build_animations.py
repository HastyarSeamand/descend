"""Bake shoulder-carry locomotion and the Gravecleaver's authored blade paths onto R15."""

import json
import math
import sys
from pathlib import Path

import bpy
from mathutils import Matrix, Vector


FPS = 30
UP = Vector((0, 1, 0))
FORWARD = Vector((0, 0, -1))
RIGHT = Vector((1, 0, 0))
IDENTITY = Matrix.Identity(4)
AXES = Matrix(((1, 0, 0, 0), (0, 0, -1, 0), (0, 1, 0, 0), (0, 0, 0, 1)))
TO_ROBLOX = AXES.inverted()
SIDES = ("Left", "Right")
MESH_TO_SWORD = Matrix(((1, 0, 0, 0), (0, 0, 1, 0), (0, -1, 0, 0), (0, 0, 0, 1)))


def rx(angle):
    return Matrix.Rotation(math.radians(angle), 4, "X")


def ry(angle):
    return Matrix.Rotation(math.radians(angle), 4, "Y")


def rz(angle):
    return Matrix.Rotation(math.radians(angle), 4, "Z")


def cframe(values):
    x, y, z, *rotation = values
    return Matrix(((*rotation[:3], x), (*rotation[3:6], y), (*rotation[6:9], z), (0, 0, 0, 1)))


def components(matrix):
    values = [*matrix.translation, *(matrix[i][j] for i in range(3) for j in range(3))]
    return [round(value, 7) for value in values]


def basis(x, y, z):
    return Matrix((x, y, z)).transposed().to_4x4()


def rejection(vector, axis):
    return vector - axis * vector.dot(axis)


def with_position(rotation, position):
    output = rotation.copy()
    output.translation = position
    return output


def smooth(t):
    return t * t * (3 - 2 * t)


def steer(current, target, limit):
    angle = current.angle(target, 0)
    return current.slerp(target, min(1, limit / max(angle, 1e-5)), target)


def grip_transform():
    tilt = math.radians(-10)
    return with_position(basis(Vector((0, -math.cos(tilt), -math.sin(tilt))),
                               Vector((0, math.sin(tilt), -math.cos(tilt))), RIGHT), (0, -0.15, 0))


HAND_SOCKET = grip_transform()
SWORD_SOCKET = Matrix.Translation((0, 0.35, 0))


class Rig:
    def __init__(self, data):
        self.parts = data["parts"]
        unsorted = {joint["p1"]: joint for joint in data["joints"]}
        self.rest = {"HumanoidRootPart": IDENTITY}
        self.joints = {}
        while unsorted:
            ready = [name for name, joint in unsorted.items() if joint["p0"] in self.rest]
            assert ready, "The R15 joints must form a tree"
            for name in ready:
                joint = unsorted.pop(name)
                parent, c0, c1 = joint["p0"], cframe(joint["c0"]), cframe(joint["c1"])
                self.joints[name] = (parent, c0, c1)
                self.rest[name] = self.rest[parent] @ c0 @ c1.inverted()
        assert len(self.joints) == 15
        self.floor = min(self.foot_floor(side, self.rest[side + "Foot"]) for side in SIDES)

    def forward(self, transforms):
        pose = {"HumanoidRootPart": IDENTITY}
        for name, (parent, c0, c1) in self.joints.items():
            pose[name] = pose[parent] @ c0 @ transforms.get(name, IDENTITY) @ c1.inverted()
        return pose

    def inverse(self, pose):
        return {name: c0.inverted() @ pose[parent].inverted() @ pose[name] @ c1
                for name, (parent, c0, c1) in self.joints.items()}

    def foot_floor(self, side, matrix):
        half = Vector(self.parts[side + "Foot"]["size"]) * 0.5
        return min((matrix @ Vector((0, -half.y, s * half.z))).y for s in (-1, 1))

    def segment(self, worlds, name, next_name, start, end, pole, preferred):
        left = self.joints[name][2].translation
        right = self.joints[next_name][1].translation
        local_axis = (right - left).normalized()
        aim = (end - start).normalized()
        aimed = (preferred.to_3x3() @ local_axis).rotation_difference(aim).to_matrix() @ preferred.to_3x3()
        # Preserve the hinge plane so elbows and knees keep consistent roll through their arcs.
        projected = rejection(pole, aim)
        source = rejection(aimed @ FORWARD, aim)
        if projected.length > 0.001 and source.length > 0.001:
            source.normalize()
            projected.normalize()
            angle = math.atan2(aim.dot(source.cross(projected)), source.dot(projected))
            aimed = Matrix.Rotation(angle, 3, aim) @ aimed
        worlds[name] = with_position(aimed.to_4x4(), start - aimed @ left)

    def chain_geometry(self, worlds, names):
        top, middle, end = names
        parent, c0, c1 = self.joints[top]
        first = (self.joints[middle][1].translation - c1.translation).length
        second = (self.joints[end][1].translation - self.joints[middle][2].translation).length
        return worlds[parent] @ c0.translation, first, second

    def chain(self, worlds, names, end_pose, pole, arm=False, state=None):
        top, middle, end = names
        origin, first, second = self.chain_geometry(worlds, names)
        end_local = self.joints[end][2].translation
        desired = end_pose @ end_local
        line = desired - origin
        direction = line.normalized()
        reach = max(abs(first - second) + 0.018, min(first + second - 0.012, line.length))
        along = (reach * reach + first * first - second * second) / (2 * reach)
        bend_axis = rejection(pole, direction)
        if bend_axis.length < 1e-4:
            bend_axis = rejection(FORWARD if abs(direction.z) < 0.9 else UP, direction)
        bend_axis.normalize()
        if state is not None:
            preferred = worlds[self.joints[top][0]].to_3x3()
            previous = state.get(top)
            if previous is not None:
                old = rejection(preferred @ previous, direction)
                if old.length > 0.02:
                    bend_axis = steer(old.normalized(), bend_axis, math.radians(33))
            state[top] = preferred.transposed() @ bend_axis
        bent = origin + direction * along + bend_axis * math.sqrt(max(0, first * first - along * along))
        far = origin + direction * reach
        preferred = worlds[self.joints[top][0]]
        front = (direction.cross(bend_axis)).cross(bent - origin).normalized()
        if arm:
            front.negate()
        self.segment(worlds, top, middle, origin, bent, front, preferred)
        next_front = (direction.cross(bend_axis)).cross(far - bent).normalized()
        if arm:
            next_front.negate()
        self.segment(worlds, middle, end, bent, far, next_front, preferred)
        worlds[end] = with_position(end_pose, end_pose.translation + far - desired)
        return (far - desired).length

    def arms(self, worlds, data, state=None, clearance=None):
        chest = worlds["UpperTorso"]
        chest_rotation = chest.to_3x3()
        blade = Vector(data["blade"]).normalized()
        if state is not None and "blade" in state:
            blade = steer(state["blade"], blade, math.radians(44))
        blade_axis = chest_rotation @ blade
        grip_at = chest @ Vector(data["grip"])
        if clearance is not None:
            lowest = (self.floor + clearance + 0.31 - grip_at.y) / 5.52
            if blade_axis.y < lowest:
                horizontal = Vector((blade_axis.x, 0, blade_axis.z)).normalized()
                elev = max(-0.93, min(0.93, lowest))
                blade_axis = horizontal * math.sqrt(1 - elev * elev) + UP * elev
                blade = chest_rotation.transposed() @ blade_axis
        edge = rejection(Vector(data["edge"]), blade)
        if edge.length < 0.10:
            edge = rejection(UP, blade)
        edge.normalize()
        if state is not None and "blade" in state:
            carried = state["blade"].rotation_difference(blade) @ state["edge"]
            roll = math.atan2(blade.dot(carried.cross(edge)), carried.dot(edge))
            limit = math.radians(23)
            edge = Matrix.Rotation(max(-limit, min(limit, roll)), 3, blade) @ carried
        if state is not None:
            state["blade"], state["edge"] = blade, edge
        sword_rotation = basis(edge, blade, edge.cross(blade))
        socket = chest @ with_position(sword_rotation, data["grip"])
        right = ("RightUpperArm", "RightLowerArm", "RightHand")
        left = ("LeftUpperArm", "LeftLowerArm", "LeftHand")
        hand_rotation = socket.to_quaternion().to_matrix().to_4x4() @ HAND_SOCKET.inverted()
        # Both palms occupy the same hilt. Pull the blade path in just enough for the two wrists to reach.
        hold = data["two"]
        palm = Vector((0, -0.15, 0))
        left_offset = -0.64
        grip = socket.translation.copy()
        left_natural = worlds["LeftHand"]
        left_shoulder = self.chain_geometry(worlds, left)[0]
        left_up = rejection(left_shoulder - grip - blade_axis * left_offset, blade_axis)
        if left_up.length < 0.15:
            left_up = rejection(chest_rotation @ Vector((-1, 0.6, 0)), blade_axis)
        left_up.normalize()
        left_forward = -blade_axis
        derived = basis(left_up.cross(left_forward), left_up, left_forward)
        left_quaternion = left_natural.to_quaternion().slerp(derived.to_quaternion(), hold)
        if state is not None:
            previous = state.get("supportRotation")
            chest_q = chest.to_quaternion()
            if previous is not None:
                old = chest_q @ previous
                angle = 2 * math.acos(min(1.0, abs(old.dot(left_quaternion))))
                left_quaternion = old.slerp(left_quaternion, min(1, math.radians(26) / max(angle, 1e-5)))
            state["supportRotation"] = chest_q.inverted() @ left_quaternion
        left_rotation = left_quaternion.to_matrix().to_4x4()
        for _ in range(6):
            for names, orientation, distance, weight in ((right, hand_rotation, 0, 1), (left, left_rotation, left_offset, hold)):
                if weight < 0.01:
                    continue
                shoulder, first, second = self.chain_geometry(worlds, names)
                joint_position = self.joints[names[-1]][2].translation
                if names == left:
                    joint_position = joint_position - palm
                wrist = grip + blade_axis * distance + orientation @ joint_position
                delta = wrist - shoulder
                max_reach = first + second - 0.038
                if delta.length > max_reach:
                    grip -= delta.normalized() * ((delta.length - max_reach) * weight)
        right_socket = with_position(socket, grip)
        right_error = self.chain(worlds, right, right_socket @ HAND_SOCKET.inverted(),
                                 chest_rotation @ Vector(data["pole"]), arm=True, state=state)
        left_target_position = grip + blade_axis * left_offset - left_rotation @ palm
        left_target = with_position(left_rotation, left_natural.translation.lerp(left_target_position, hold))
        left_elbow = worlds["LeftLowerArm"] @ self.joints["LeftLowerArm"][2].translation
        left_pole = (left_elbow - left_shoulder).normalized().lerp(chest_rotation @ Vector((-0.78, -0.65, 0.25)), hold)
        if hold > 0.001 or state is not None:
            left_error = self.chain(worlds, left, left_target, left_pole, arm=True, state=state)
        else:
            left_error = 0
        return right_error, left_error if hold > 0.99 else 0

    def locomotion(self, frame, count, run, carry):
        u = (frame % count) / count
        sin = math.sin(math.tau * u)
        cos = math.cos(math.tau * u)
        vertical = math.cos(math.tau * 2 * u)
        lean = 14 if run else 5
        turn = 7 if run else 4
        root = Matrix.Translation((0.045 * sin, -0.36 - (0.14 if run else 0.075) * vertical, -0.03 if run else 0))
        transforms = {"LowerTorso": root @ ry(-turn * cos * 0.65) @ rx(-lean * 0.20),
                      "UpperTorso": ry(turn * cos) @ rx(-lean + (2 if run else 1) * vertical) @ rz(-1.7 * sin),
                      "Head": ry(-turn * cos * 0.5) @ rx(lean * 0.80) @ rz(0.8 * sin),
                      "LeftUpperArm": rz(-11 if run else -8) @ rx((16 if run else 13) * cos + (20 if run else 6)),
                      "LeftLowerArm": rx(50 + 17 * cos if run else 19 + 8 * cos),
                      "LeftHand": rx(-5 if run else -2)}
        worlds = self.forward(transforms)
        stance = 0.40 if run else 0.62
        travel = 2.13 if run else 1.80
        peak = 0.91 if run else 0.47
        end_poses = {}
        for index, side in enumerate(SIDES):
            phase = (u + index * 0.5) % 1
            outgoing = phase < stance
            if outgoing:
                t = phase / stance
                along = (0.5 - t) * travel
                pitch = (14 if run else 17) * (1 - smooth(min(t / 0.28, 1)))
                pitch -= (34 if run else 27) * smooth(max(0, (t - 0.68) / 0.32))
                lift = 0
            else:
                t = (phase - stance) / (1 - stance)
                along = (smooth(t) - 0.5) * travel
                pitch = -(34 if run else 27) * (1 - smooth(t)) + (14 if run else 17) * smooth(t)
                lift = peak * (math.sin(math.pi * t) ** 1.35) * (1.15 - 0.30 * t)
            sign = -1 if side == "Left" else 1
            position = Vector((sign * (0.47 if run else 0.49), 0, -along))
            foot = with_position(ry(-sign * (5 if run else 7)) @ rx(pitch), position)
            foot.translation.y += self.floor + lift - self.foot_floor(side, foot)
            end_poses[side] = foot
        # Lower the pelvis just enough to keep both foot targets in reach at contact.
        maximum = 0
        for side, foot in end_poses.items():
            names = (side + "UpperLeg", side + "LowerLeg", side + "Foot")
            hip, first, second = self.chain_geometry(worlds, names)
            delta = hip - foot @ self.joints[side + "Foot"][2].translation
            room = (first + second - 0.045) ** 2 - delta.x ** 2 - delta.z ** 2
            maximum = max(maximum, delta.y - math.sqrt(max(0.01, room)))
        for name in worlds:
            if name != "HumanoidRootPart":
                worlds[name].translation.y -= maximum
        for side in SIDES:
            names = (side + "UpperLeg", side + "LowerLeg", side + "Foot")
            assert self.chain(worlds, names, end_poses[side], FORWARD) < 0.002
        carry = dict(carry)
        carry["grip"] = (0.66, 1.08 + (0.035 if run else 0.016) * vertical, -0.19)
        carry["blade"] = (-0.73, -0.17 + 0.025 * sin, 0.66)
        self.arms(worlds, carry)
        return worlds

    def combat(self, data, hop=0, state=None, clearance=None):
        trans = {"LowerTorso": Matrix.Translation((0, -data["dip"], 0)) @ ry(data["spin"]) @ rx(-data["rfwd"]) @ rz(-data["rside"]),
                 "UpperTorso": ry(data["yaw"]) @ rx(-data["lean"]) @ rz(data["wroll"]),
                 "Head": ry(data["neck"]) @ rx(data["npitch"]),
                 "LeftUpperArm": rz(data["lroll"] - 7 * (1 - data["two"])) @ rx(data["lpitch"] + 4),
                 "LeftLowerArm": rx(data["lelbow"] + 12 * (1 - data["two"]))}
        for side in SIDES:
            key = side[0].lower()
            mult = -1 if side == "Left" else 1
            trans[side + "UpperLeg"] = rz(mult * data[key + "spread"]) @ rx(data[key + "hip"])
            trans[side + "LowerLeg"] = rx(data[key + "knee"])
            trans[side + "Foot"] = rx(-0.77 * (data[key + "hip"] + data[key + "knee"]))
        worlds = self.forward(trans)
        ground = min(self.foot_floor(side, worlds[side + "Foot"]) for side in SIDES)
        for name in worlds:
            if name != "HumanoidRootPart":
                worlds[name].translation.y += self.floor - ground + hop
        error = self.arms(worlds, data, state, clearance)
        return worlds, error


def clips_from_reference(rig, reference):
    carry = reference["carry"]
    clips = []

    def add(name, frames, markers, loop=False, priority="Action", speed=None):
        clips.append({"name": name, "frames": frames, "markers": markers, "loop": loop, "priority": priority, "speed": speed})

    idle = []
    for i in range(49):
        breath = math.sin(math.tau * (i % 48) / 48)
        pose = dict(carry, lean=3 + 0.8 * breath, lhip=5, lknee=-10, rhip=-3, rknee=-9, lspread=4, rspread=4)
        pose["grip"] = (0.66, 1.08 + 0.018 * breath, -0.19)
        idle.append(rig.combat(pose)[0])
    add("ShoulderCarry", idle, {}, True, "Idle")
    for name, loop_frames, distance, stance, run in (("GravecleaverWalk", 28, 1.80, 0.62, False), ("GravecleaverRun", 20, 2.13, 0.40, True)):
        frames = [rig.locomotion(i, loop_frames, run, carry) for i in range(loop_frames + 1)]
        add(name, frames, {0: "LeftFoot", loop_frames // 2: "RightFoot"}, True, "Movement", round(distance * FPS / loop_frames / stance, 2))

    max_errors = [0, 0]

    def combat_clip(item, state, previous=None):
        frames = []
        markers = {}
        if "hit" in item:
            markers[item["hit"]] = "Hit"
        for n, pose in enumerate(item["poses"]):
            if n == 0 and previous is not None:
                frames.append(previous)
                continue
            # The older procedural curves can change direction sharply over one frame.
            # A narrow filter retains the impact pose while smoothing the approach and exit.
            if 0 < n < len(item["poses"]) - 1:
                before, after = item["poses"][n - 1], item["poses"][n + 1]
                weight = 0.14 if n == item.get("hit") else 0.24
                pose = dict(pose)
                for key in ("grip", "blade", "edge", "pole"):
                    pose[key] = Vector(pose[key]) * (1 - 2 * weight) + (Vector(before[key]) + Vector(after[key])) * weight
            hop = 0
            clearance = 0.10
            if item["name"] == "GraveSlam" and 4 < n < item["hit"]:
                hop = 0.53 * math.sin(math.pi * (n - 4) / (item["hit"] - 4))
            if item["name"] == "GraveSlam" and item["hit"] <= n < item["hit"] + 8:
                clearance = -0.55
            worlds, errors = rig.combat(pose, hop, state, clearance)
            for i, error in enumerate(errors):
                max_errors[i] = max(max_errors[i], error)
            frames.append(worlds)
        return frames, markers

    combo_frames, combo_markers = [], {}
    style_state = {}
    for item in [*reference["light"], reference["recover"]]:
        frames, markers = combat_clip(item, style_state, combo_frames[-1] if combo_frames else None)
        add("ReturnToCarry" if item["name"] == "Recover" else item["name"], frames, markers)
        offset = max(0, len(combo_frames) - 1)
        combo_frames.extend(frames[1:] if combo_frames else frames)
        combo_markers.update({offset + frame: marker for frame, marker in markers.items()})
    add("GravecleaverCombo", combo_frames, combo_markers)
    heavy, heavy_markers = combat_clip(reference["heavy"], {})
    add("ReaverCleave", heavy, heavy_markers)
    print(f"Grip reach error, maximum (studs): right {max_errors[0]:.4f}, support {max_errors[1]:.4f}")
    return clips


def material(name, color):
    mat = bpy.data.materials.new(name)
    mat.diffuse_color = (*color, 1)
    return mat


def make_armature(rig):
    armature = bpy.data.armatures.new("Studio R15")
    avatar = bpy.data.objects.new("Gravecleaver — R15", armature)
    bpy.context.collection.objects.link(avatar)
    bpy.context.view_layer.objects.active = avatar
    avatar.select_set(True)
    bpy.ops.object.mode_set(mode="EDIT")
    for name, rest in rig.rest.items():
        bone = armature.edit_bones.new(name)
        position = AXES @ rest.translation
        bone.head = position
        bone.tail = position + Vector((0, 0.27, 0))
        if name in rig.joints:
            bone.parent = armature.edit_bones[rig.joints[name][0]]
    bpy.ops.object.mode_set(mode="OBJECT")
    avatar.select_set(False)
    avatar.hide_render = True
    avatar.show_in_front = True
    for bone in avatar.pose.bones:
        bone.rotation_mode = "QUATERNION"
    return avatar


def build_actions(avatar, rig, clips):
    animation = avatar.animation_data_create()
    for clip in clips:
        action = bpy.data.actions.new(clip["name"])
        action.use_fake_user = True
        action.use_frame_range = True
        action.frame_start = 0
        action.frame_end = len(clip["frames"]) - 1
        animation.action = action
        last = {}
        for frame, pose in enumerate(clip["frames"]):
            scene_pose = {name: AXES @ matrix @ TO_ROBLOX for name, matrix in pose.items()}
            for name, matrix in scene_pose.items():
                bone = avatar.pose.bones[name]
                rest = bone.bone.matrix_local
                parent = rig.joints[name][0] if name in rig.joints else None
                if parent:
                    rest = avatar.pose.bones[parent].bone.matrix_local.inverted() @ rest
                    matrix = scene_pose[parent].inverted() @ matrix
                location, rotation, _ = (rest.inverted() @ matrix).decompose()
                if name in last:
                    rotation.make_compatible(last[name])
                last[name] = rotation.copy()
                bone.location, bone.rotation_quaternion = location, rotation
                bone.keyframe_insert("location", frame=frame, group=name)
                bone.keyframe_insert("rotation_quaternion", frame=frame, group=name)
        for frame, label in clip["markers"].items():
            action.pose_markers.new(label).frame = frame
        for curve in action.layers[0].strips[0].channelbag(animation.action_slot).fcurves:
            for key in curve.keyframe_points:
                key.interpolation = "LINEAR"
        clip["action"] = action
        clip["slot"] = animation.action_slot


def follow_bone(obj, avatar, bone):
    constraint = obj.constraints.new("COPY_TRANSFORMS")
    constraint.target = avatar
    constraint.subtarget = bone


def rounded_box(name, dimensions, bevel, mat):
    bpy.ops.mesh.primitive_cube_add(size=1)
    obj = bpy.context.object
    obj.name = name
    obj.dimensions = dimensions
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    modifier = obj.modifiers.new("Rounded edges", "BEVEL")
    modifier.width = bevel
    modifier.segments = 3
    obj.data.materials.append(mat)
    return obj


def build_visuals(avatar, rig, sword_path, sword_data):
    neutral = material("Mannequin • slate", (0.26, 0.31, 0.39))
    upper = material("Mannequin • armor", (0.45, 0.53, 0.64))
    accent = material("Mannequin • gloves and boots", (0.17, 0.21, 0.29))
    sword_mats = {"Blade": material("Iron", (0.34, 0.37, 0.42)), "Fittings": material("Black iron", (0.15, 0.17, 0.20)),
                  "Grip": material("Oxblood wrap", (0.26, 0.075, 0.078)), "CurseCrack": material("Ember", (0.92, 0.16, 0.065))}
    for name in rig.joints:
        x, y, z = rig.parts[name]["size"]
        width = 0.79 if "Arm" in name else 0.84 if "Leg" in name else 0.8 if "Hand" in name else 1
        material_choice = accent if name.endswith(("Hand", "Foot")) else upper if name in ("Head", "UpperTorso") else neutral
        obj = rounded_box(name + " display", (x * width, z * (0.82 if width < 1 else 1), y), min(0.20, y * 0.24), material_choice)
        follow_bone(obj, avatar, name)

    sword_anchor = bpy.data.objects.new("Gravecleaver • hand socket", None)
    bpy.context.collection.objects.link(sword_anchor)
    follow_bone(sword_anchor, avatar, "RightHand")
    with bpy.data.libraries.load(str(sword_path), link=False) as (available, target):
        target.objects = [name for name in available.objects if name in sword_mats]
    grip_at_pivot = cframe(sword_data["Grip"]["cframe"])
    scale = sword_data["Blade"]["size"][1] / 5.05
    for obj in target.objects:
        assert obj is not None
        bpy.context.collection.objects.link(obj)
        obj.parent = sword_anchor
        obj.matrix_parent_inverse = IDENTITY
        transform = HAND_SOCKET @ SWORD_SOCKET.inverted() @ grip_at_pivot.inverted() @ MESH_TO_SWORD @ Matrix.Scale(scale, 4)
        obj.matrix_basis = AXES @ transform
        obj.data.materials.clear()
        obj.data.materials.append(sword_mats[obj.name])
        for polygon in obj.data.polygons:
            polygon.material_index = 0


def export_sequences(rig, clips, folder):
    sequences = []
    for clip in clips:
        frames = []
        previous = None
        jumps = []
        gaps = []
        for frame, pose in enumerate(clip["frames"]):
            transforms = rig.inverse(pose)
            check = rig.forward(transforms)
            assert max((check[name].translation - matrix.translation).length for name, matrix in pose.items()) < 0.0001
            if previous:
                for name, matrix in transforms.items():
                    old, new = previous[name].to_quaternion(), matrix.to_quaternion()
                    degrees = math.degrees(2 * math.acos(min(1.0, abs(old.dot(new)))))
                    jumps.append((round(degrees, 1), frame, name))
            previous = transforms
            sword = pose["RightHand"] @ HAND_SOCKET
            gaps.append(((sword @ Vector((0, 5.52, 0))).y - rig.floor, frame))
            frames.append({"poses": [components(transforms[name]) for name in rig.joints], "marker": clip["markers"].get(frame)})
        print(f"{clip['name']}: max joint changes {sorted(jumps, reverse=True)[:3]}, lowest blade tip {min(gaps)}")
        sequences.append({key: clip[key] for key in ("name", "loop", "priority", "speed")} | {"frames": frames})
    assert all(sequences[i]["frames"][0] == (sequences[i]["frames"][-1] | {"marker": sequences[i]["frames"][0]["marker"]}) for i in range(3)), "Locomotion loop discontinuity"
    output = {"fps": FPS, "joints": [[key, value[0]] for key, value in rig.joints.items()], "clips": sequences}
    (folder / "sequences.json").write_text(json.dumps(output, separators=(",", ":")), encoding="utf-8")


def stage(scene, floor):
    scene.render.engine = "BLENDER_WORKBENCH"
    scene.render.resolution_x, scene.render.resolution_y = 368, 320
    scene.render.resolution_percentage = 100
    scene.render.fps = FPS
    scene.render.image_settings.file_format = "PNG"
    scene.render.film_transparent = False
    scene.display.render_aa = "OFF"
    shading = scene.display.shading
    shading.light = "STUDIO"
    shading.studiolight_rotate_z = 0.4
    shading.color_type = "MATERIAL"
    shading.background_type = "WORLD"
    shading.show_cavity = True
    shading.cavity_type = "BOTH"
    shading.show_shadows = True
    scene.world.color = (0.036, 0.044, 0.067)
    platform = rounded_box("Preview floor", (180, 180, 0.2), 0.02, material("Backdrop", (0.095, 0.108, 0.135)))
    platform.location.z = floor - 0.105


def camera_for(clip, side, scene):
    angle = (1.0, -0.38, 0.29) if side else (-0.62, 1.0, 0.36)
    direction = Vector(angle).normalized()
    orientation = (-direction).to_track_quat("-Z", "Y")
    screen_x, screen_y = orientation @ Vector((1,0,0)), orientation @ Vector((0,1,0))
    points = []
    for pose in clip["frames"]:
        for name, part in pose.items():
            if name != "HumanoidRootPart":
                center = AXES @ part.translation
                points.extend(center + offset for offset in (screen_x * 0.8, screen_x * -0.8, screen_y * 0.85, screen_y * -0.85))
        sword = pose["RightHand"] @ HAND_SOCKET
        for x in (-0.87, 0.87):
            for y in (-1.66, 5.52):
                points.append(AXES @ (sword @ Vector((x, y, 0))))
    horizontal = [screen_x.dot(point) for point in points]
    vertical = [screen_y.dot(point) for point in points]
    width, height = max(horizontal) - min(horizontal), max(vertical) - min(vertical)
    focus = screen_x * ((max(horizontal) + min(horizontal)) * 0.5) + screen_y * ((max(vertical) + min(vertical)) * 0.5)
    data = bpy.data.cameras.new("Side" if side else "Three quarter")
    camera = bpy.data.objects.new(data.name, data)
    bpy.context.collection.objects.link(camera)
    camera.location = focus + direction * 24
    camera.rotation_euler = orientation.to_euler()
    data.type = "ORTHO"
    data.ortho_scale = max(width, height * (scene.render.resolution_x / scene.render.resolution_y)) * 1.13
    scene.camera = camera
    return camera


def main():
    root, sword_file, operation = sys.argv[sys.argv.index("--") + 1:]
    folder = Path(root).resolve()
    inputs = json.loads((folder / "animation_place.json").read_text(encoding="utf-8"))
    reference = json.loads((folder / "combat_reference.json").read_text(encoding="utf-8"))
    rig = Rig(inputs["standard"])
    clips = clips_from_reference(rig, reference)
    export_sequences(rig, clips, folder)
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.world = bpy.data.worlds.new("Animation stage")
    avatar = make_armature(rig)
    build_actions(avatar, rig, clips)
    build_visuals(avatar, rig, Path(sword_file), inputs["reference"]["sword"]["content"])
    stage(scene, rig.floor)
    animation = avatar.animation_data
    demo = [clip for clip in clips if clip["name"] in {"GravecleaverWalk", "GravecleaverRun", "GravecleaverCombo", "ReaverCleave"}]
    animation.action, animation.action_slot = demo[0]["action"], demo[0]["slot"]
    scene.frame_start, scene.frame_end = 0, len(demo[0]["frames"]) - 1
    scene.frame_set(0)
    camera_for(demo[0], False, scene)
    bpy.context.view_layer.objects.active = avatar
    avatar.select_set(True)
    bpy.ops.wm.save_as_mainfile(filepath=str(folder / "Gravecleaver R15 Animation.blend"))
    if operation == "bake":
        return
    for clip in demo:
        directory = folder / "frames" / clip["name"]
        directory.mkdir(parents=True, exist_ok=True)
        animation.action, animation.action_slot = clip["action"], clip["slot"]
        for side in (False, True):
            camera = camera_for(clip, side, scene)
            count = len(clip["frames"])
            frames = list(range(count if not clip["loop"] else count - 1))
            if operation == "proof":
                frames = sorted(set([*range(0, count, max(1, count // 8)), *clip["markers"], count - 1]))
            for frame in frames:
                scene.frame_set(frame)
                playing = avatar.pose.bones["UpperTorso"].matrix.translation
                expected = AXES @ clip["frames"][frame]["UpperTorso"].translation
                assert (playing - expected).length < 0.001, f"Inactive Blender action: {clip['name']} frame {frame}"
                destination = directory / f"{'side' if side else 'front'}_{frame:03}.png"
                scene.render.filepath = str(destination)
                bpy.ops.render.render(write_still=True)
                assert destination.stat().st_size > 1000, destination
            bpy.data.objects.remove(camera, do_unlink=True)


if __name__ == "__main__":
    main()
