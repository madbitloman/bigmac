"""Renders the BigMac app icon headlessly.

    /Applications/Blender.app/Contents/MacOS/Blender -b -P scripts/logo.py -- Resources/AppIcon.png

A rounded gradient tile (macOS icon shape) with a pearl shield and a glowing sparkle:
cleanup + protection.
"""
import math
import sys

import bmesh
import bpy
from mathutils import Vector

out = sys.argv[sys.argv.index("--") + 1] if "--" in sys.argv else "AppIcon.png"

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene


def hex_rgba(h, a=1.0):
    h = h.lstrip("#")
    srgb = [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]
    lin = [c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in srgb]
    return (*lin, a)


def outline_object(name, points, depth, bevel, z):
    """Extrudes a closed 2D outline into a bevelled solid."""
    mesh = bpy.data.meshes.new(name)
    bm = bmesh.new()
    verts = [bm.verts.new((x, y, 0)) for x, y in points]
    bm.faces.new(verts)
    bm.to_mesh(mesh)
    bm.free()
    obj = bpy.data.objects.new(name, mesh)
    scene.collection.objects.link(obj)
    obj.location.z = z
    solid = obj.modifiers.new("solid", "SOLIDIFY")
    solid.thickness = depth
    solid.offset = 1
    bev = obj.modifiers.new("bevel", "BEVEL")
    bev.width = bevel
    bev.segments = 8
    bev.limit_method = "ANGLE"
    bev.harden_normals = True
    return obj


def rounded_rect(half, radius, seg=24):
    pts = []
    for cx, cy, start in [(half - radius, half - radius, 0), (-half + radius, half - radius, 90),
                          (-half + radius, -half + radius, 180), (half - radius, -half + radius, 270)]:
        for i in range(seg + 1):
            a = math.radians(start + 90 * i / seg)
            pts.append((cx + radius * math.cos(a), cy + radius * math.sin(a)))
    return pts


def shield(w, h, seg=40):
    """Classic shield: gently arched top, straight-ish sides curving to a point."""
    pts = []
    top = h * 0.5
    for i in range(seg + 1):  # arched top, right → left
        t = i / seg
        x = w * (0.5 - t)
        pts.append((x, top + 0.06 * h * math.cos((t - 0.5) * math.pi) - 0.03 * h))
    for i in range(1, seg):  # left side down to the tip
        t = i / seg
        x = -w * 0.5 * (1 - t ** 2.6)
        y = top - 0.03 * h - t * h * 0.97
        pts.append((x, y))
    pts.append((0, -h * 0.5))
    for i in range(seg - 1, 0, -1):  # right side back up
        t = i / seg
        pts.append((w * 0.5 * (1 - t ** 2.6), top - 0.03 * h - t * h * 0.97))
    return pts


def star(r_out, r_in, points=4, seg=10):
    """Four-point sparkle with concave sides."""
    pts = []
    for p in range(points):
        a0 = 2 * math.pi * p / points + math.pi / 2
        a1 = a0 + 2 * math.pi / points
        tip0 = Vector((math.cos(a0), math.sin(a0))) * r_out
        tip1 = Vector((math.cos(a1), math.sin(a1))) * r_out
        ctrl = Vector((math.cos((a0 + a1) / 2), math.sin((a0 + a1) / 2))) * r_in
        for i in range(seg):
            t = i / seg
            q = (1 - t) ** 2 * tip0 + 2 * (1 - t) * t * ctrl + t ** 2 * tip1
            pts.append((q.x, q.y))
    return pts


def material(name, build):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    build(m.node_tree)
    return m


def tile_mat(nt):
    n, l = nt.nodes, nt.links
    bsdf = n["Principled BSDF"]
    coord = n.new("ShaderNodeTexCoord")
    sep = n.new("ShaderNodeSeparateXYZ")
    add = n.new("ShaderNodeMath"); add.operation = "SUBTRACT"
    rng = n.new("ShaderNodeMapRange"); rng.inputs["From Min"].default_value = -2.2; rng.inputs["From Max"].default_value = 2.2
    ramp = n.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].color = hex_rgba("#120B3A")
    ramp.color_ramp.elements[1].color = hex_rgba("#0FB39A")
    mid = ramp.color_ramp.elements.new(0.5); mid.color = hex_rgba("#1D4ED8")
    l.new(coord.outputs["Object"], sep.inputs[0])
    l.new(sep.outputs["Y"], add.inputs[0]); l.new(sep.outputs["X"], add.inputs[1])
    l.new(add.outputs[0], rng.inputs["Value"])
    l.new(rng.outputs[0], ramp.inputs["Fac"])
    l.new(ramp.outputs["Color"], bsdf.inputs["Base Color"])
    bsdf.inputs["Roughness"].default_value = 0.32
    bsdf.inputs["Coat Weight"].default_value = 0.6
    bsdf.inputs["Coat Roughness"].default_value = 0.08


def pearl_mat(nt):
    b = nt.nodes["Principled BSDF"]
    b.inputs["Base Color"].default_value = hex_rgba("#F4F7FF")
    b.inputs["Roughness"].default_value = 0.28
    b.inputs["Coat Weight"].default_value = 1.0
    b.inputs["Coat Roughness"].default_value = 0.05
    b.inputs["Subsurface Weight"].default_value = 0.15


def glow_mat(color, strength):
    def build(nt):
        b = nt.nodes["Principled BSDF"]
        b.inputs["Base Color"].default_value = hex_rgba(color)
        b.inputs["Emission Color"].default_value = hex_rgba(color)
        b.inputs["Emission Strength"].default_value = strength
        b.inputs["Roughness"].default_value = 0.2
    return build


# Tile: 2 × 2 units, macOS-like corner radius.
tile = outline_object("Tile", rounded_rect(1.0, 0.45), depth=0.22, bevel=0.07, z=0)
tile.data.materials.append(material("Tile", tile_mat))

shield_obj = outline_object("Shield", shield(1.1, 1.25), depth=0.16, bevel=0.06, z=0.22)
shield_obj.location.y = -0.04
shield_obj.data.materials.append(material("Pearl", pearl_mat))

spark = outline_object("Sparkle", star(0.36, 0.07), depth=0.08, bevel=0.025, z=0.38)
spark.location.y = 0.02
spark.data.materials.append(material("Glow", glow_mat("#10C9A8", 2.2)))

small = outline_object("SparkleSmall", star(0.17, 0.035), depth=0.05, bevel=0.015, z=0.3)
small.location = (0.55, 0.58, 0.3)
small.data.materials.append(material("White", glow_mat("#FFFFFF", 3.0)))

for obj in (tile, shield_obj, spark, small):
    bpy.context.view_layer.objects.active = obj
    obj.select_set(True)
    bpy.ops.object.shade_smooth()
    obj.select_set(False)

# Soft shadow under the tile on a transparent background.
bpy.ops.mesh.primitive_plane_add(size=12, location=(0, 0, -0.001))
catcher = bpy.context.active_object
catcher.is_shadow_catcher = True

# Lights.
def area(name, loc, energy, size, color="#FFFFFF"):
    light = bpy.data.lights.new(name, "AREA")
    light.energy = energy
    light.size = size
    light.color = hex_rgba(color)[:3]
    obj = bpy.data.objects.new(name, light)
    obj.location = loc
    obj.rotation_euler = (Vector((0, 0, 0)) - Vector(loc)).to_track_quat("-Z", "Y").to_euler()
    scene.collection.objects.link(obj)

area("Key", (-2.5, 2.5, 5), 420, 4)
area("Fill", (3, -2, 4), 90, 5, "#BFD7FF")
area("Rim", (0, 4, 1.2), 220, 3, "#9FFFE9")

world = bpy.data.worlds.new("World")
world.use_nodes = True
world.node_tree.nodes["Background"].inputs["Color"].default_value = hex_rgba("#20243A")
world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0.25
scene.world = world

# Camera: orthographic, slight tilt for depth. Body fills ~80% of the canvas like Apple's icon grid.
cam_data = bpy.data.cameras.new("Cam")
cam_data.type = "ORTHO"
cam_data.ortho_scale = 2.0 * 1024 / 824
cam = bpy.data.objects.new("Cam", cam_data)
tilt = math.radians(8)
cam.location = (0, -10 * math.sin(tilt), 10 * math.cos(tilt))
cam.rotation_euler = (tilt, 0, 0)
scene.collection.objects.link(cam)
scene.camera = cam

# Render settings.
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
scene.cycles.samples = 192
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
