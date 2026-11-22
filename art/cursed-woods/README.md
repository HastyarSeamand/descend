# Cursed Woods trail props

Four original environment meshes share two procedural texture atlases. Run this from this folder with Blender 5.3 to build the editable scene, textures, and four FBXs.

```text
blender -b --factory-startup -P build_woods_props.py
```

Pass `-- --preview` to render an additional close-up of each prop. See the [export manifest](fbx/manifest.json) for scale, triangle counts, and each prop’s atlas.

For Studio, import the generated FBXs individually using **Stud** as the scale unit, then add a **SurfaceAppearance**. Assign the corresponding atlas’s color, normal, and roughness maps. Roadside also has a metalness map and an emissive mask that picks out the lantern panes.
