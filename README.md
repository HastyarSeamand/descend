# The Descent

The Descent is an indie dark-fantasy action game in development for Roblox. You play a cursed warrior who fights with the Gravecleaver, a heavy greatsword, and pushes through hostile territory one encounter at a time. Every swing is player-controlled.

The current world prototype starts on **Cursed Woods**, an island of winding paths, monster camps, and ruins. The longer-term design is an island journey toward a central Pit, with a Curse meter that rewards taking risks and rebirth that carries progress between runs.

![Four original Cursed Woods trail props rendered in Blender](art/cursed-woods/Cursed%20Woods%20Preview.jpg)

## What’s here

| Folder | What you can explore |
| --- | --- |
| [`src/`](src/) | Luau from the Studio prototype, arranged by Roblox service. Includes the Gravecleaver combat and touch controls, eight monster rigs and their encounter logic, and the island terrain and day/night systems. |
| [`art/cursed-woods/`](art/cursed-woods/) | Blender generators and an export manifest for the Split Deadwood, Wayfarer Grave, Grave Lantern, and Witchcap Log. |
| [`sword/`](sword/) | The Gravecleaver’s editable Blender model and a generator that can export it as FBX. |
| [`animations/`](animations/) | An editable Blender R15 animation study with the pose data and bake script for the Gravecleaver’s carry, locomotion, and attacks. |

## Try part of the project

- **Roblox Studio:** [Build the island terrain and preview its lighting in a blank place](docs/studio.md). The guide also maps the combat code to its Studio dependencies.
- **Blender 5.3:** Open [the Gravecleaver animation file](animations/gravecleaver%20r15%20v1/Gravecleaver%20R15%20Animation.blend) and select an action on the R15 armature, or [generate the four Cursed Woods props](art/cursed-woods/README.md).

This is a development source snapshot. The full Studio place, its imported dependencies, and the packaged playable build are outside this repository. Some Luau scripts reference Roblox-hosted sounds or animations whose availability depends on the experience’s permissions.
