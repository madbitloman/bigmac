"""Renders the BigMac app icon headlessly: a photoreal double-decker sesame burger on the app's tile.

    /Applications/Blender.app/Contents/MacOS/Blender -b -P scripts/logo.py -- "$PWD/Resources/AppIcon.png"

Generic burger only: no restaurant logos, arches, wordmarks or brand colours.
"""
import math
import random
import sys

import bmesh
import bpy
from mathutils import Matrix, Vector

out = sys.argv[sys.argv.index("--") + 1] if "--" in sys.argv else "AppIcon.png"
random.seed(7)

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene


def hex_rgba(h, a=1.0):
    h = h.lstrip("#")
    srgb = [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    lin = [c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in srgb]
    return (*lin, a)


def link(obj, parent=None):
    scene.collection.objects.link(obj)
    if parent:
        obj.parent = parent
    return obj


def smooth(obj):
    for p in obj.data.polygons:
        p.use_smooth = True


def mesh_obj(name, bm, parent=None):
    mesh = bpy.data.meshes.new(name)
    bm.to_mesh(mesh)
    bm.free()
    obj = link(bpy.data.objects.new(name, mesh), parent)
    smooth(obj)
    return obj


# ---------------------------------------------------------------- materials

def principled(name, color, rough=0.5, sss=0.0, coat=0.0, spec=0.5):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    b = m.node_tree.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = hex_rgba(color)
    b.inputs["Roughness"].default_value = rough
    b.inputs["Subsurface Weight"].default_value = sss
    b.inputs["Subsurface Radius"].default_value = (0.3, 0.15, 0.08)
    b.inputs["Subsurface Scale"].default_value = 0.05
    b.inputs["Coat Weight"].default_value = coat
    b.inputs["Specular IOR Level"].default_value = spec
    return m


def add_noise(m, colors, scale, bump, detail=6, axis_ramp=None):
    """Colour variation from noise (or a local-Z gradient) plus bump."""
    nt = m.node_tree
    n, l = nt.nodes, nt.links
    b = n["Principled BSDF"]
    coord = n.new("ShaderNodeTexCoord")
    noise = n.new("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = scale
    noise.inputs["Detail"].default_value = detail
    l.new(coord.outputs["Object"], noise.inputs["Vector"])
    ramp = n.new("ShaderNodeValToRGB")
    els = ramp.color_ramp.elements
    els[0].color = hex_rgba(colors[0])
    els[1].color = hex_rgba(colors[-1])
    for i, c in enumerate(colors[1:-1], 1):
        els.new(i / (len(colors) - 1)).color = hex_rgba(c)
    if axis_ramp:
        sep = n.new("ShaderNodeSeparateXYZ")
        rng = n.new("ShaderNodeMapRange")
        rng.inputs["From Min"].default_value, rng.inputs["From Max"].default_value = axis_ramp
        mix = n.new("ShaderNodeMath"); mix.operation = "MULTIPLY_ADD"
        mix.inputs[1].default_value = 0.15
        l.new(coord.outputs["Object"], sep.inputs[0])
        l.new(sep.outputs["Z"], rng.inputs["Value"])
        l.new(noise.outputs["Fac"], mix.inputs[0])
        l.new(rng.outputs[0], mix.inputs[2])
        l.new(mix.outputs[0], ramp.inputs["Fac"])
    else:
        l.new(noise.outputs["Fac"], ramp.inputs["Fac"])
    l.new(ramp.outputs["Color"], b.inputs["Base Color"])
    bmp = n.new("ShaderNodeBump")
    bmp.inputs["Strength"].default_value = bump
    fine = n.new("ShaderNodeTexNoise")
    fine.inputs["Scale"].default_value = scale * 6
    fine.inputs["Detail"].default_value = 8
    l.new(coord.outputs["Object"], fine.inputs["Vector"])
    l.new(fine.outputs["Fac"], bmp.inputs["Height"])
    l.new(bmp.outputs["Normal"], b.inputs["Normal"])
    return m


bun_mat = add_noise(principled("Bun", "#C9782E", rough=0.62, sss=0.12, coat=0.05, spec=0.3),
                    ["#EDB86E", "#CF8435", "#A9601F", "#86441A"], 3.0, 0.18, axis_ramp=(0.16, 0.62))
bun_side_mat = add_noise(principled("BunSide", "#D98F45", rough=0.65, sss=0.12, coat=0.0, spec=0.3),
                         ["#EDBE7E", "#D08A42", "#A85E24"], 4.0, 0.06)
patty_mat = add_noise(principled("Patty", "#4A2A17", rough=0.62, spec=0.4),
                      ["#2A160B", "#4E2C17", "#6B3D20", "#2E180C"], 18.0, 0.9, detail=10)
cheese_mat = principled("Cheese", "#F6A623", rough=0.3, sss=0.35, coat=0.25)
lettuce_mat = add_noise(principled("Lettuce", "#86C440", rough=0.35, sss=0.4),
                        ["#5E9E2A", "#9AD457", "#C9EC8E"], 9.0, 0.3)
sauce_mat = principled("Sauce", "#F0C27E", rough=0.15, sss=0.3, coat=0.6)
pickle_mat = add_noise(principled("Pickle", "#4F7A28", rough=0.25, sss=0.3, coat=0.5),
                       ["#3B5F1D", "#6F9A3A", "#A9C66B"], 14.0, 0.2)
seed_mat = principled("Sesame", "#F4E3B8", rough=0.4, sss=0.2)

# ---------------------------------------------------------------- geometry

rig = link(bpy.data.objects.new("Burger", None))


def cylinder(name, r, h, z, mat, bevel, segs=128, displace=0.0):
    bpy.ops.mesh.primitive_cylinder_add(vertices=segs, radius=r, depth=h, location=(0, 0, z + h / 2))
    obj = bpy.context.active_object
    obj.parent = rig
    obj.data.materials.append(mat)
    smooth(obj)
    bev = obj.modifiers.new("bevel", "BEVEL")
    bev.width = bevel
    bev.segments = 8
    bev.harden_normals = True
    if displace:
        sub = obj.modifiers.new("sub", "SUBSURF")
        sub.levels = sub.render_levels = 2
        tex = bpy.data.textures.new(name + "Tex", "CLOUDS")
        tex.noise_scale = 0.12
        disp = obj.modifiers.new("disp", "DISPLACE")
        disp.texture = tex
        disp.strength = displace
        disp.mid_level = 0.5
    return obj


def ruffled_disc(name, r, z, mat, waves=11, amp=0.03, wobble=0.045, thickness=0.012, droop=0.04):
    bm = bmesh.new()
    rings, segs = 14, 160
    phase = [random.uniform(0, 6.28) for _ in range(3)]
    grid = []
    for i in range(rings + 1):
        t = i / rings
        row = []
        for j in range(segs):
            th = 2 * math.pi * j / segs
            edge = r + wobble * (math.sin(7 * th + phase[0]) + 0.6 * math.sin(13 * th + phase[1]) + 0.4 * math.sin(23 * th + phase[2]))
            rr = edge * t
            zz = z + amp * math.sin(waves * th + phase[1]) * t ** 2 - droop * t ** 4
            row.append(bm.verts.new((rr * math.cos(th), rr * math.sin(th), zz)))
        grid.append(row)
    for i in range(rings):
        for j in range(segs):
            bm.faces.new((grid[i][j], grid[i][(j + 1) % segs], grid[i + 1][(j + 1) % segs], grid[i + 1][j]))
    bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=1e-5)
    obj = mesh_obj(name, bm, rig)
    obj.data.materials.append(mat)
    solid = obj.modifiers.new("solid", "SOLIDIFY")
    solid.thickness = thickness
    sub = obj.modifiers.new("sub", "SUBSURF")
    sub.levels = sub.render_levels = 1
    return obj


def cheese_slice(z, size=1.2, angle=20):
    bm = bmesh.new()
    bmesh.ops.create_grid(bm, x_segments=60, y_segments=60, size=size / 2)
    rot = Matrix.Rotation(math.radians(angle), 4, "Z")
    for v in bm.verts:
        v.co = rot @ v.co
        d = math.hypot(v.co.x, v.co.y)
        if d > 0.6:  # melt over the patty edge
            v.co.z -= (d - 0.6) * 0.45 + (d - 0.6) ** 2 * 0.5
        v.co.z += z
    obj = mesh_obj("Cheese", bm, rig)
    obj.data.materials.append(cheese_mat)
    solid = obj.modifiers.new("solid", "SOLIDIFY")
    solid.thickness = 0.018
    sub = obj.modifiers.new("sub", "SUBSURF")
    sub.levels = sub.render_levels = 1
    return obj


def top_bun(z, r=0.69, h=0.42):
    bm = bmesh.new()
    bmesh.ops.create_uvsphere(bm, u_segments=128, v_segments=64, radius=1.0)
    bmesh.ops.bisect_plane(bm, geom=bm.verts[:] + bm.edges[:] + bm.faces[:], plane_co=(0, 0, 0), plane_no=(0, 0, 1), clear_inner=True)
    bmesh.ops.holes_fill(bm, edges=bm.edges[:], sides=0)
    for v in bm.verts:
        # Flatter crown, fuller shoulders, like a real bun.
        zz = v.co.z ** 1.25 if v.co.z > 0 else 0
        v.co = Vector((v.co.x * r * (1 + 0.04 * (1 - v.co.z)), v.co.y * r * (1 + 0.04 * (1 - v.co.z)), z + zz * h))
    obj = mesh_obj("TopBun", bm, rig)
    obj.data.materials.append(bun_mat)
    bev = obj.modifiers.new("bevel", "BEVEL")
    bev.width = 0.05
    bev.segments = 6
    bev.limit_method = "ANGLE"
    return obj, r, h


def sesame(z, r, h, count=95):
    bm = bmesh.new()
    golden = math.pi * (3 - math.sqrt(5))
    placed = 0
    i = 0
    while placed < count and i < count * 4:
        i += 1
        uz = 1 - (i / (count * 4)) * 0.85  # upper part of the dome only
        if uz < 0.3:
            break
        rad = math.sqrt(1 - uz * uz)
        th = golden * i + random.uniform(-0.25, 0.25)
        ux, uy = rad * math.cos(th), rad * math.sin(th)
        zz = uz ** 1.25
        p = Vector((ux * r, uy * r, z + zz * h))
        normal = Vector((ux / r, uy / r, uz / h)).normalized()
        seed = bmesh.ops.create_uvsphere(bm, u_segments=10, v_segments=6, radius=1.0)
        align = normal.to_track_quat("Z", "Y").to_matrix().to_4x4()
        spin = Matrix.Rotation(random.uniform(0, math.pi), 4, "Z")
        scale = Matrix.Diagonal((0.034, 0.019, 0.009, 1))
        bmesh.ops.transform(bm, matrix=Matrix.Translation(p + normal * 0.004) @ align @ spin @ scale, verts=seed["verts"])
        placed += 1
    obj = mesh_obj("Sesame", bm, rig)
    obj.data.materials.append(seed_mat)


# Stack, bottom to top (units ≈ burger radius 0.65).
cylinder("BottomBun", 0.65, 0.2, 0.0, bun_side_mat, bevel=0.085)
cylinder("Sauce1", 0.62, 0.02, 0.2, sauce_mat, bevel=0.009)
ruffled_disc("Lettuce1", 0.7, 0.225, lettuce_mat)
cylinder("Patty1", 0.68, 0.14, 0.25, patty_mat, bevel=0.04, displace=0.035)
cheese_slice(0.392)
cylinder("MiddleBun", 0.645, 0.16, 0.405, bun_side_mat, bevel=0.07)
cylinder("Sauce2", 0.62, 0.02, 0.565, sauce_mat, bevel=0.009)
ruffled_disc("Lettuce2", 0.69, 0.588, lettuce_mat, waves=9)
for k, (ang, rr) in enumerate([(200, 0.56), (250, 0.5), (300, 0.57)]):
    p = cylinder(f"Pickle{k}", 0.13, 0.02, 0.598, pickle_mat, bevel=0.008, segs=48)
    p.location.x = rr * math.cos(math.radians(ang))
    p.location.y = rr * math.sin(math.radians(ang))
    p.rotation_euler = (random.uniform(-0.08, 0.08), random.uniform(-0.08, 0.08), 0)
cylinder("Patty2", 0.68, 0.14, 0.61, patty_mat, bevel=0.04, displace=0.035)
_, br, bh = top_bun(0.755)
sesame(0.755, br, bh)

# Centre the burger, tilt its top toward the camera, and turn it a little.
for child in rig.children:
    child.location.z -= 0.6
rig.scale = (0.9, 0.9, 0.9)
rig.rotation_euler = (math.radians(24), 0, math.radians(-12))
rig.location = (0, -0.2, 0.04)

# ---------------------------------------------------------------- tile backdrop

def rounded_rect(half, radius, seg=24):
    pts = []
    for cx, cy, start in [(half - radius, half - radius, 0), (-half + radius, half - radius, 90),
                          (-half + radius, -half + radius, 180), (half - radius, -half + radius, 270)]:
        for i in range(seg + 1):
            a = math.radians(start + 90 * i / seg)
            pts.append((cx + radius * math.cos(a), cy + radius * math.sin(a)))
    return pts


bm = bmesh.new()
bm.faces.new([bm.verts.new((x, y, 0)) for x, y in rounded_rect(1.0, 0.45)])
tile = mesh_obj("Tile", bm)
tile.rotation_euler = (math.radians(90), 0, 0)  # face the camera; thickness grows toward it
tile.location.y = 1.0
solid = tile.modifiers.new("solid", "SOLIDIFY"); solid.thickness = 0.2; solid.offset = 1
bev = tile.modifiers.new("bevel", "BEVEL"); bev.width = 0.06; bev.segments = 8; bev.limit_method = "ANGLE"; bev.harden_normals = True

tm = bpy.data.materials.new("Tile")
tm.use_nodes = True
n, l = tm.node_tree.nodes, tm.node_tree.links
b = n["Principled BSDF"]
coord = n.new("ShaderNodeTexCoord"); grad = n.new("ShaderNodeTexGradient"); grad.gradient_type = "SPHERICAL"
mapping = n.new("ShaderNodeMapping"); mapping.inputs["Location"].default_value = (0.15, 0.25, 0); mapping.inputs["Scale"].default_value = (0.55, 0.55, 1)
ramp = n.new("ShaderNodeValToRGB")
ramp.color_ramp.elements[0].color = hex_rgba("#0B1030")
ramp.color_ramp.elements[1].color = hex_rgba("#2F6BFF")
ramp.color_ramp.elements.new(0.55).color = hex_rgba("#1A2C7A")
l.new(coord.outputs["Object"], mapping.inputs["Vector"]); l.new(mapping.outputs[0], grad.inputs["Vector"])
l.new(grad.outputs["Fac"], ramp.inputs["Fac"]); l.new(ramp.outputs["Color"], b.inputs["Base Color"])
b.inputs["Roughness"].default_value = 0.35
b.inputs["Coat Weight"].default_value = 0.5
tile.data.materials.append(tm)

# ---------------------------------------------------------------- light, camera, render

def area(name, loc, energy, size, color="#FFFFFF", target=(0, 0, 0)):
    light = bpy.data.lights.new(name, "AREA")
    light.energy, light.size = energy, size
    light.color = hex_rgba(color)[:3]
    obj = link(bpy.data.objects.new(name, light))
    obj.location = loc
    obj.rotation_euler = (Vector(target) - Vector(loc)).to_track_quat("-Z", "Y").to_euler()

area("Key", (-2.2, -3.5, 3.2), 380, 3.5, "#FFE6C7")
area("Fill", (3.0, -3.5, 0.0), 140, 4, "#C9DAFF")
area("Top", (0.3, -0.6, 3.5), 160, 3, "#FFF4E0")
area("Rim", (2.2, 0.4, 1.6), 260, 1.5, "#FFD7A8", target=(0, -0.2, 0.2))

world = bpy.data.worlds.new("World")
world.use_nodes = True
world.node_tree.nodes["Background"].inputs["Color"].default_value = hex_rgba("#2A2420")
world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.35
scene.world = world

cam_data = bpy.data.cameras.new("Cam")
cam_data.type = "ORTHO"
cam_data.ortho_scale = 2.0 * 1024 / 824
cam = link(bpy.data.objects.new("Cam", cam_data))
cam.location = (0, -10, 0)
cam.rotation_euler = (math.radians(90), 0, 0)
scene.camera = cam

scene.render.engine = "CYCLES"
prefs = bpy.context.preferences.addons["cycles"].preferences
try:
    prefs.compute_device_type = "METAL"
    prefs.get_devices()
    for d in prefs.devices:
        d.use = True
    scene.cycles.device = "GPU"
except Exception:
    scene.cycles.device = "CPU"
scene.cycles.samples = 256
scene.cycles.use_denoising = True
scene.render.film_transparent = True
scene.render.resolution_x = scene.render.resolution_y = 1024
scene.render.image_settings.file_format = "PNG"
scene.render.image_settings.color_mode = "RGBA"
scene.view_settings.view_transform = "AgX"
scene.view_settings.look = "AgX - Medium High Contrast"
scene.render.filepath = out
bpy.ops.render.render(write_still=True)
print("ICON_WRITTEN", out)
