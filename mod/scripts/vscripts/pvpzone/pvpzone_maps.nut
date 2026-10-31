// PvPZone map data. Each line only applies on the map it names.
// Energy walls are NOT here: their points are in mod.json (pvpzone_walls_<map>).
// Everything below is optional.
//
// Coordinates: x/y of each polygon corner, in order around the area (clockwise or counter-clockwise).
// The z of polygon points is ignored; height limits come from minZ / maxZ.
// Record them in game with pvpzone_edit 1 + pvpzone_add + pvpzone_print boundary / pvpzone_print oob 5 (see README), then paste here.
//
//   PvPZone_SetBoundary( map, [ corners ], minZ, maxZ )            script safety net, one per map
//   PvPZone_AddOOBZone( map, [ corners ], minZ, maxZ, seconds )    countdown area inside the boundary
//   PvPZone_AddSpawn( map, origin, < 0, yaw, 0 > )                 extra pilot + titan spawn

global function PvPZoneMaps_Init

void function PvPZoneMaps_Init()
{
	// ---- example (made-up numbers, replace with your own recorded points) ----
	// PvPZone_SetBoundary( "mp_angel_city", [ < -1500, -1200, 0 >, < 1800, -1200, 0 >, < 1800, 2200, 0 >, < -1500, 2200, 0 > ], -600, 2600 )
	// PvPZone_AddOOBZone( "mp_angel_city", [ < 900, 900, 0 >, < 1500, 900, 0 >, < 1500, 1600, 0 >, < 900, 1600, 0 > ], 600, 2600, 5.0 )
	// PvPZone_AddSpawn( "mp_angel_city", < -1200, -900, 120 >, < 0, 45, 0 > )
}
