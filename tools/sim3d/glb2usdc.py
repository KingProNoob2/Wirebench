import bpy, sys
from mathutils import Vector
argv = sys.argv[sys.argv.index("--") + 1:]
src, dst = argv[0], argv[1]
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=src)

pcb_finishes = {
    "Duino_S_PCB": (0.008, 0.070, 0.032, 1),
    "Duino_S_Shield_PCB": (0.012, 0.018, 0.024, 1),
}
for obj in bpy.context.scene.objects:
    source_name = obj.data.name if obj.type == 'MESH' else obj.name
    finish_name = source_name.replace('-', '_')
    if obj.type != 'MESH' or finish_name not in pcb_finishes:
        continue
    for slot in obj.material_slots:
        material = slot.material
        if material is None or not material.use_nodes:
            continue
        shader = next((node for node in material.node_tree.nodes if node.type == 'BSDF_PRINCIPLED'), None)
        if shader is None:
            continue
        shader.inputs['Base Color'].default_value = pcb_finishes[finish_name]
        shader.inputs['Metallic'].default_value = 0.05
        shader.inputs['Roughness'].default_value = 0.32
        shader.inputs['Coat Weight'].default_value = 0.45
        shader.inputs['Coat Roughness'].default_value = 0.18

def world_center(obj):
    mins = [1e18]*3; maxs = [-1e18]*3
    for c in obj.bound_box:
        w = obj.matrix_world @ Vector(c)
        for i in range(3):
            mins[i] = min(mins[i], w[i]); maxs[i] = max(maxs[i], w[i])
    return Vector([(a + b) / 2 for a, b in zip(mins, maxs)])

meshes = [o for o in bpy.context.scene.objects if o.type == 'MESH']
centers = sorted((world_center(o) for o in meshes), key=lambda v: v.length)
median = centers[len(centers) // 2]
removed = 0
for obj in meshes:
    if (world_center(obj) - median).length > 0.2:
        bpy.data.objects.remove(obj, do_unlink=True)
        removed += 1
print(f"removed {removed} outlier meshes, median {[round(v, 3) for v in median]}")

# Emit the model frame (world-space center + extents) for the runtime to stack and frame the
# boards without trusting RealityKit's load-time bounds.
mins = [1e18]*3; maxs = [-1e18]*3
for obj in bpy.context.scene.objects:
    if obj.type != 'MESH': continue
    for c in obj.bound_box:
        w = obj.matrix_world @ Vector(c)
        for i in range(3):
            mins[i] = min(mins[i], w[i]); maxs[i] = max(maxs[i], w[i])
import json as _json
frame = {"center": [(a + b) / 2 for a, b in zip(mins, maxs)],
         "extents": [maxs[i] - mins[i] for i in range(3)]}
with open(dst.replace(".usdc", "-frame.json"), "w") as fh:
    _json.dump(frame, fh)

bpy.ops.wm.usd_export(filepath=dst)
print("exported", dst, frame["center"], frame["extents"])
