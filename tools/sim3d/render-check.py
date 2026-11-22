import bpy, sys, math
argv = sys.argv[sys.argv.index("--") + 1:]
src, dst = argv[0], argv[1]
bpy.ops.wm.read_factory_settings(use_empty=True)
if src.endswith(".usdc") or src.endswith(".usd"):
    bpy.ops.wm.usd_import(filepath=src)
else:
    bpy.ops.import_scene.gltf(filepath=src)
# frame all objects
mins = [1e9]*3; maxs = [-1e9]*3
for obj in bpy.context.scene.objects:
    if obj.type == 'MESH':
        for corner in obj.bound_box:
            w = obj.matrix_world @ bpy.mathutils_Vector(corner) if False else obj.matrix_world @ __import__('mathutils').Vector(corner)
            for i in range(3):
                mins[i] = min(mins[i], w[i]); maxs[i] = max(maxs[i], w[i])
center = [(a+b)/2 for a, b in zip(mins, maxs)]
size = max(maxs[i]-mins[i] for i in range(3))
cam = bpy.data.cameras.new("cam"); cam.clip_end = 100
cam_obj = bpy.data.objects.new("cam", cam)
bpy.context.scene.collection.objects.link(cam_obj)
bpy.context.scene.camera = cam_obj
# isometric-ish view from above (Blender: Z up)
direction = __import__('mathutils').Vector((1, -1, 1.4)).normalized()
cam_obj.location = __import__('mathutils').Vector(center) + direction * size * 1.3
look = center
cam_obj.rotation_euler = (__import__('mathutils').Vector(look) - cam_obj.location).to_track_quat('-Z', 'Y').to_euler()
sun = bpy.data.lights.new("sun", 'SUN'); sun.energy = 4
sun_obj = bpy.data.objects.new("sun", sun); bpy.context.scene.collection.objects.link(sun_obj)
sun_obj.rotation_euler = (math.radians(50), 0, math.radians(30))
bpy.context.scene.render.engine = 'BLENDER_EEVEE'
bpy.context.scene.render.resolution_x = 1400
bpy.context.scene.render.resolution_y = 1000
bpy.context.scene.render.filepath = dst
bpy.ops.render.render(write_still=True)
print("rendered", dst)
