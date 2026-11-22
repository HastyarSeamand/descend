# Explore Cursed Woods in Studio

Use a new Roblox Studio Baseplate for these steps. Delete its Baseplate part so it does not cover the generated terrain.

1. In `ReplicatedStorage`, create a folder named `Descent`. Add a **ModuleScript** named `IslandLayout` and paste the contents of [IslandLayout.luau](../src/ReplicatedStorage/Descent/IslandLayout.luau) into it.
2. In `ServerStorage`, add a **ModuleScript** named `IslandBuilder` and paste the contents of [IslandBuilder.luau](../src/ServerStorage/IslandBuilder.luau) into it.
3. Run the following in Studio’s Command Bar in Edit mode. The builder writes terrain in strips across the layout bounds.

   ```lua
   local layout = require(game.ReplicatedStorage.Descent.IslandLayout)
   local builder = require(game.ServerStorage.IslandBuilder)
   for z = layout.Bounds.Z0, layout.Bounds.Z1 - 40, 40 do
       builder.chunk(layout, z, z + 40)
       task.wait()
   end
   ```

4. Add a **Script** named `DayNight` inside a `Descent` folder in `ServerScriptService` and paste [DayNight.server.luau](../src/ServerScriptService/Descent/DayNight.server.luau) into it. Move the SpawnLocation above the terrain near the dock coordinates in `IslandLayout.Spawn`, then press Play. By default the day and night phases each last three minutes. Set a numeric `DayNightHalf` attribute on Workspace to shorten each phase for a test.

The terrain module generates the coast, paths, slopes, and water. Props, buildings, and spawn positions are separate Studio objects.

## Read the gameplay code

- [WeaponConfig](../src/ReplicatedStorage/Descent/WeaponConfig.luau) defines move timing and tuning. [WeaponService](../src/ServerScriptService/Descent/WeaponService.server.luau) handles server-side hits and resources. [CombatClient](../src/StarterPlayer/StarterPlayerScripts/Descent/CombatClient.client.luau) handles player input, blade motion, and effects. Together they expect the place’s remote events, weapon models, and effects folders.
- [DescentMonsters](../src/ServerScriptService/DescentMonsters/) includes the roster, pose data, mesh data, and runtime for the island camps. The runtime builds the original monsters with Roblox’s editable mesh and image APIs and reads the campsite positions from `IslandLayout.Camps`.
