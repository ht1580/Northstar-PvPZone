// PvPZone: turn part of a large map into a small PvP arena (server side only).
//
//  - Energy walls: any number of surfaces, each defined by 3D points in order (any angle: vertical,
//    sloped, horizontal ceilings/floors). Points live in mod.json (pvpzone_walls_<map>).
//    Pieces are solid like real walls: block players, titans, NPCs, bullets, projectiles, splash and AI sight.
//  - Play area (pvpzone_boundary_<map> in mod.json): leaving it = instant "fell out of the map" death.
//    Covers players (pilot, titan, rodeo), NPC titans are moved back inside, other NPCs die.
//  - Out-of-bounds countdown zones and custom spawns (pvpzone_maps.nut).
//  - Edit tools in game (pvpzone_edit 1): aim and record points, build a preview wall instantly, print config.

global function PvPZone_Init
global function PvPZone_SetBoundary
global function PvPZone_AddOOBZone
global function PvPZone_AddSpawn
global function PvPZone_IsPointInPlayArea

const float PVPZONE_PUSH_IN = 4.0
const float PVPZONE_WARN_INTERVAL = 1.5
const float PVPZONE_PLANAR_TOLERANCE = 2.0 // points further than this from the first plane -> split into triangles

global struct PvPZoneArea
{
	array<vector> poly
	float minZ = -99999.0
	float maxZ = 99999.0
	float oobTime = 0.0
	vector bbMins
	vector bbMaxs
}

global struct PvPZoneOOBState
{
	bool inZone = false
	float deadline = 0.0
	float remaining = -1.0
	float leftAt = 0.0
}

struct
{
	// boundary / oob / spawns (pvpzone_maps.nut)
	bool hasBoundary = false
	PvPZoneArea& boundary
	array<PvPZoneArea> oobZones
	array<vector> customSpawnOrigins
	array<vector> customSpawnAngles
	array<vector> safeSpawns
	array<vector> titanSafeSpawns
	bool warnedNoSafeSpawn = false
	bool fallMode = true
	bool ceilingKill = false
	int npcCheckFrame = 0

	// energy walls
	asset wallModel
	bool wallModelOk = false
	bool wallMeasured = false
	vector pieceMins
	vector pieceMaxs
	string thinAxis = "none"
	float tileStep = 0.0
	array<entity> wallPieces
	array<entity> previewPieces
	array<vector> pieceCenters // for spawn checks
	float pieceRadius = 0.0
	table<entity, bool> blockedSpawns

	// per player
	table<entity, vector> lastSafe
	table<entity, PvPZoneOOBState> oob
	table<entity, float> lastWarn
	table<entity, array<vector> > editPoints
} file

// ===================================================================================
// Init
// ===================================================================================

void function PvPZone_Init()
{
	if ( GetMapName() == "mp_lobby" )
		return
	if ( !GetConVarBool( "pvpzone_enabled" ) )
		return

	if ( GetConVarBool( "pvpzone_walls" ) )
	{
		file.wallModel = StringToAsset( strip( GetConVarString( "pvpzone_wall_model" ) ) )
		PrecacheModel( file.wallModel )
		file.wallModelOk = true
		file.thinAxis = strip( GetConVarString( "pvpzone_wall_thin_axis" ) ).tolower()
	}

	AddSpawnpointValidationRule( PvPZone_SpawnRule )
	AddCallback_OnPlayerRespawned( PvPZone_OnPlayerRespawned )
	AddCallback_OnClientDisconnected( PvPZone_OnClientDisconnected )
	AddCallback_EntitiesDidLoad( PvPZone_EntitiesDidLoad )

	if ( GetConVarFloat( "pvpzone_farz" ) > 0.0 )
		AddSpawnCallback( "env_fog_controller", PvPZone_SetFarZ )

	if ( GetConVarBool( "pvpzone_edit" ) )
		PvPZone_RegisterEditCommands()
}

// ===================================================================================
// Config API (pvpzone_maps.nut)
// ===================================================================================

void function PvPZone_SetBoundary( string mapName, array<vector> points, float minZ, float maxZ )
{
	if ( mapName != GetMapName() )
		return
	if ( points.len() < 3 )
	{
		printt( "[PvPZone] boundary for " + mapName + " needs at least 3 points" )
		return
	}

	file.boundary = PvPZone_MakeArea( points, minZ, maxZ, 0.0 )
	file.hasBoundary = true
}

void function PvPZone_AddOOBZone( string mapName, array<vector> points, float minZ, float maxZ, float seconds )
{
	if ( mapName != GetMapName() )
		return
	if ( points.len() < 3 )
		return

	file.oobZones.append( PvPZone_MakeArea( points, minZ, maxZ, max( 0.5, seconds ) ) )
}

void function PvPZone_AddSpawn( string mapName, vector origin, vector angles )
{
	if ( mapName != GetMapName() )
		return

	file.customSpawnOrigins.append( origin )
	file.customSpawnAngles.append( angles )
}

bool function PvPZone_IsPointInPlayArea( vector point )
{
	if ( !file.hasBoundary )
		return true
	return PvPZone_PointInArea( point, file.boundary )
}

PvPZoneArea function PvPZone_MakeArea( array<vector> points, float minZ, float maxZ, float oobTime )
{
	PvPZoneArea area
	area.poly = clone points
	area.minZ = min( minZ, maxZ )
	area.maxZ = max( minZ, maxZ )
	area.oobTime = oobTime

	float x0 = points[0].x
	float x1 = points[0].x
	float y0 = points[0].y
	float y1 = points[0].y
	foreach ( vector p in points )
	{
		x0 = min( x0, p.x )
		x1 = max( x1, p.x )
		y0 = min( y0, p.y )
		y1 = max( y1, p.y )
	}
	area.bbMins = < x0, y0, area.minZ >
	area.bbMaxs = < x1, y1, area.maxZ >
	return area
}

// ===================================================================================
// 2D geometry
// ===================================================================================

bool function PvPZone_PointInPoly2D( float px, float py, array<float> xs, array<float> ys )
{
	bool inside = false
	int n = xs.len()
	int j = n - 1
	for ( int i = 0; i < n; i++ )
	{
		if ( ( ys[i] > py ) != ( ys[j] > py ) )
		{
			float xCross = ( xs[j] - xs[i] ) * ( py - ys[i] ) / ( ys[j] - ys[i] ) + xs[i]
			if ( px < xCross )
				inside = !inside
		}
		j = i
	}
	return inside
}

float function PvPZone_DistToPolyEdgeSq2D( float px, float py, array<float> xs, array<float> ys )
{
	float best = 999999999999.0
	int n = xs.len()
	for ( int i = 0; i < n; i++ )
	{
		int k = ( i + 1 ) % n
		float abx = xs[k] - xs[i]
		float aby = ys[k] - ys[i]
		float lenSq = abx * abx + aby * aby
		float t = 0.0
		if ( lenSq > 0.0 )
			t = clamp( ( ( px - xs[i] ) * abx + ( py - ys[i] ) * aby ) / lenSq, 0.0, 1.0 )
		float dx = px - ( xs[i] + abx * t )
		float dy = py - ( ys[i] + aby * t )
		best = min( best, dx * dx + dy * dy )
	}
	return best
}

bool function PvPZone_PointInArea( vector p, PvPZoneArea area )
{
	if ( p.z < area.minZ || p.z > area.maxZ )
		return false
	return PvPZone_InsideXY( p, area )
}

bool function PvPZone_InsideXY( vector p, PvPZoneArea area )
{
	if ( p.x < area.bbMins.x || p.x > area.bbMaxs.x || p.y < area.bbMins.y || p.y > area.bbMaxs.y )
		return false

	array<float> xs
	array<float> ys
	foreach ( vector v in area.poly )
	{
		xs.append( v.x )
		ys.append( v.y )
	}
	return PvPZone_PointInPoly2D( p.x, p.y, xs, ys )
}

vector function PvPZone_ClosestEdgePoint2D( vector p, array<vector> poly )
{
	float bestDist = 999999999999.0
	vector best = p
	int n = poly.len()
	for ( int i = 0; i < n; i++ )
	{
		vector a = poly[i]
		vector b = poly[ ( i + 1 ) % n ]
		float abx = b.x - a.x
		float aby = b.y - a.y
		float lenSq = abx * abx + aby * aby
		float t = 0.0
		if ( lenSq > 0.0 )
			t = clamp( ( ( p.x - a.x ) * abx + ( p.y - a.y ) * aby ) / lenSq, 0.0, 1.0 )
		float cx = a.x + abx * t
		float cy = a.y + aby * t
		float d = ( p.x - cx ) * ( p.x - cx ) + ( p.y - cy ) * ( p.y - cy )
		if ( d < bestDist )
		{
			bestDist = d
			best = < cx, cy, p.z >
		}
	}
	return best
}

// ===================================================================================
// Energy walls
// ===================================================================================

// "x y z, x y z, x y z; x y z, ..."   ';' separates surfaces, ',' separates points
array<array<vector> > function PvPZone_ParseSurfaces( string data )
{
	array<array<vector> > surfaces
	foreach ( string surfStr in split( data, ";" ) )
	{
		array<vector> pts
		foreach ( string ptStr in split( surfStr, "," ) )
		{
			array<string> nums
			foreach ( string tok in split( strip( ptStr ), " \t" ) )
			{
				if ( strip( tok ) != "" )
					nums.append( strip( tok ) )
			}
			if ( nums.len() == 0 )
				continue
			if ( nums.len() != 3 )
			{
				printt( "[PvPZone] bad point '" + ptStr + "' (need: x y z)" )
				continue
			}
			float x = nums[0].tofloat()
			float y = nums[1].tofloat()
			float z = nums[2].tofloat()
			pts.append( < x, y, z > )
		}

		if ( pts.len() >= 3 )
			surfaces.append( pts )
		else if ( pts.len() > 0 )
			printt( "[PvPZone] surface with " + pts.len() + " points skipped (need at least 3)" )
	}
	return surfaces
}

entity function PvPZone_CreateWallPiece( vector origin, vector angles )
{
	entity piece = CreateEntity( "prop_dynamic" )
	piece.SetValueForModelKey( file.wallModel )
	piece.kv.solid = SOLID_VPHYSICS // default collision group: blocks players, titans, NPCs, bullets, projectiles
	piece.kv.fadedist = -1
	piece.kv.renderamt = 255
	piece.kv.rendercolor = GetConVarString( "pvpzone_wall_color" )
	piece.SetOrigin( origin )
	piece.SetAngles( angles )
	piece.SetBlocksRadiusDamage( true )
	DispatchSpawn( piece )
	piece.SetBlocksLOS( true )
	if ( !GetConVarBool( "pvpzone_wall_visible" ) )
		piece.Hide() // hidden props keep their collision
	return piece
}

// measure the model once: collision bounds and tile step
bool function PvPZone_MeasureWallModel( vector at )
{
	if ( file.wallMeasured )
		return file.tileStep > 0.0

	file.wallMeasured = true
	entity probe = PvPZone_CreateWallPiece( at, < 0, 0, 0 > )
	file.pieceMins = probe.GetBoundingMins()
	file.pieceMaxs = probe.GetBoundingMaxs()
	probe.Destroy()

	vector size = file.pieceMaxs - file.pieceMins
	printt( "[PvPZone] wall model " + GetConVarString( "pvpzone_wall_model" ) + " size " + int( size.x ) + " x " + int( size.y ) + " x " + int( size.z ) + ", thin axis '" + file.thinAxis + "'" )

	// the two in-plane dimensions of the piece
	float inPlane
	if ( file.thinAxis == "x" )
		inPlane = min( size.y, size.z )
	else if ( file.thinAxis == "y" )
		inPlane = min( size.x, size.z )
	else if ( file.thinAxis == "z" )
		inPlane = min( size.x, size.y )
	else
		inPlane = min( size.x, size.y ) * 0.75 // round pieces (dome): denser grid so circles leave no gaps

	if ( inPlane < 8.0 )
	{
		printt( "[PvPZone] WARNING: wall model has no usable collision bounds (missing model?), walls disabled" )
		file.tileStep = 0.0
		return false
	}

	file.tileStep = inPlane * clamp( GetConVarFloat( "pvpzone_wall_spacing" ), 0.2, 1.0 )
	file.pieceRadius = Length( size ) * 0.5
	return true
}

// angles that put the model's thin axis along the surface normal
vector function PvPZone_PieceAngles( vector normal, vector inPlaneDir )
{
	vector surf = AnglesOnSurface( normal, inPlaneDir ) // model up = normal, model forward = inPlaneDir
	if ( file.thinAxis == "x" )
		return AnglesCompose( surf, < -90, 0, 0 > ) // model forward -> normal
	if ( file.thinAxis == "y" )
		return AnglesCompose( surf, < 0, 0, 90 > ) // model left -> normal
	return surf
}

vector function PvPZone_RotateLocal( vector local, vector angles )
{
	return AnglesToForward( angles ) * local.x - AnglesToRight( angles ) * local.y + AnglesToUp( angles ) * local.z
}

// tile one planar polygon; returns pieces created
int function PvPZone_TilePlanar( array<vector> pts, array<entity> outPieces, int budget )
{
	vector p0 = pts[0]
	vector e1 = pts[1] - p0
	vector normal = < 0, 0, 0 >
	for ( int i = 2; i < pts.len(); i++ )
	{
		vector c = CrossProduct( e1, pts[i] - p0 )
		if ( Length( c ) > 1.0 )
		{
			normal = Normalize( c )
			break
		}
	}
	if ( Length( normal ) < 0.5 || Length( e1 ) < 1.0 )
	{
		printt( "[PvPZone] degenerate surface skipped (points in a line)" )
		return 0
	}

	vector u = Normalize( e1 )
	vector v = CrossProduct( normal, u )

	array<float> xs
	array<float> ys
	float minA = 0.0
	float maxA = 0.0
	float minB = 0.0
	float maxB = 0.0
	foreach ( vector p in pts )
	{
		float a = DotProduct( p - p0, u )
		float b = DotProduct( p - p0, v )
		xs.append( a )
		ys.append( b )
		minA = min( minA, a )
		maxA = max( maxA, a )
		minB = min( minB, b )
		maxB = max( maxB, b )
	}

	float step = file.tileStep
	float reachSq = ( step * 0.5 ) * ( step * 0.5 )
	array<vector> angleSet = [ PvPZone_PieceAngles( normal, u ) ]
	if ( file.thinAxis != "x" && file.thinAxis != "y" && file.thinAxis != "z" )
		angleSet.append( PvPZone_PieceAngles( normal * -1.0, u ) ) // round open pieces (dome): close the back side

	vector localCenter = ( file.pieceMins + file.pieceMaxs ) * 0.5
	bool centerPieces = file.thinAxis == "x" || file.thinAxis == "y" || file.thinAxis == "z"

	// grid centred on the surface so any overhang is split evenly between opposite edges
	int countA = maxint( 1, int( ceil( ( maxA - minA ) / step ) ) )
	int countB = maxint( 1, int( ceil( ( maxB - minB ) / step ) ) )
	float startA = ( minA + maxA ) * 0.5 - ( countA - 1 ) * step * 0.5
	float startB = ( minB + maxB ) * 0.5 - ( countB - 1 ) * step * 0.5

	int made = 0
	for ( int ia = 0; ia < countA; ia++ )
	{
		float a = startA + ia * step
		for ( int ib = 0; ib < countB; ib++ )
		{
			float b = startB + ib * step
			// keep tiles whose square touches the polygon, so edges have no gaps
			if ( !PvPZone_PointInPoly2D( a, b, xs, ys ) && PvPZone_DistToPolyEdgeSq2D( a, b, xs, ys ) > reachSq )
				continue

			vector target = p0 + u * a + v * b
			foreach ( vector ang in angleSet )
			{
				if ( made >= budget )
					return made
				vector origin = target
				if ( centerPieces )
					origin = target - PvPZone_RotateLocal( localCenter, ang )
				outPieces.append( PvPZone_CreateWallPiece( origin, ang ) )
				file.pieceCenters.append( target )
				made++
			}
		}
	}
	return made
}

// tile any surface: planar -> one pass, otherwise fan triangles from the first point
int function PvPZone_BuildSurface( array<vector> pts, array<entity> outPieces, int budget )
{
	if ( !PvPZone_MeasureWallModel( pts[0] ) )
		return 0

	vector cross = CrossProduct( pts[1] - pts[0], pts[2] - pts[0] )
	bool planar = Length( cross ) > 1.0
	vector normal = < 0, 0, 1 >
	if ( planar )
	{
		normal = Normalize( cross )
		foreach ( vector p in pts )
		{
			if ( fabs( DotProduct( p - pts[0], normal ) ) > PVPZONE_PLANAR_TOLERANCE )
			{
				planar = false
				break
			}
		}
	}

	if ( planar )
		return PvPZone_TilePlanar( pts, outPieces, budget )

	int made = 0
	for ( int i = 1; i < pts.len() - 1; i++ )
	{
		array<vector> tri = [ pts[0], pts[i], pts[i + 1] ]
		made += PvPZone_TilePlanar( tri, outPieces, budget - made )
	}
	return made
}

void function PvPZone_BuildConfiguredWalls()
{
	string mapName = GetMapName()
	string data = ""
	if ( PvPZone_KnownMap( mapName ) )
		data = GetConVarString( "pvpzone_walls_" + mapName )
	if ( strip( data ) == "" )
		return

	array<array<vector> > surfaces = PvPZone_ParseSurfaces( data )
	int budget = GetConVarInt( "pvpzone_wall_max_pieces" )
	int total = 0
	foreach ( array<vector> surf in surfaces )
	{
		total += PvPZone_BuildSurface( surf, file.wallPieces, budget - total )
		if ( total >= budget )
		{
			printt( "[PvPZone] WARNING: hit pvpzone_wall_max_pieces (" + budget + "), some walls are incomplete" )
			break
		}
	}
	printt( "[PvPZone] walls built: " + surfaces.len() + " surfaces, " + total + " pieces" )
}

// convars must be declared in mod.json; only these maps have a pvpzone_walls_<map> entry
bool function PvPZone_KnownMap( string mapName )
{
	array<string> maps = [
		"mp_angel_city", "mp_black_water_canal", "mp_coliseum", "mp_coliseum_column", "mp_colony02",
		"mp_complex3", "mp_crashsite3", "mp_drydock", "mp_eden", "mp_forwardbase_kodai", "mp_glitch",
		"mp_grave", "mp_homestead", "mp_relic02", "mp_rise", "mp_thaw", "mp_wargames",
		"mp_lf_deck", "mp_lf_meadow", "mp_lf_stacks", "mp_lf_township", "mp_lf_traffic", "mp_lf_uma"
	]
	return maps.contains( mapName )
}

// spawnpoints inside or touching a wall piece are never used
void function PvPZone_ComputeBlockedSpawns()
{
	if ( file.pieceCenters.len() == 0 )
		return

	float r = file.pieceRadius + 40.0
	float rSq = r * r
	array<string> classes = [ "info_spawnpoint_human", "info_spawnpoint_titan", "info_spawnpoint_human_start", "info_spawnpoint_titan_start" ]
	foreach ( string cls in classes )
	{
		foreach ( entity sp in GetEntArrayByClass_Expensive( cls ) )
		{
			vector o = sp.GetOrigin() + < 0, 0, 36 >
			foreach ( vector c in file.pieceCenters )
			{
				vector d = o - c
				if ( d.x * d.x + d.y * d.y + d.z * d.z < rSq )
				{
					file.blockedSpawns[ sp ] <- true
					break
				}
			}
		}
	}
	printt( "[PvPZone] " + file.blockedSpawns.len() + " spawnpoints blocked by walls" )
}

// ===================================================================================
// Map load
// ===================================================================================

void function PvPZone_EntitiesDidLoad()
{
	thread PvPZone_Setup_Threaded()
}

void function PvPZone_Setup_Threaded()
{
	WaitEndFrame() // let gamemode spawn filtering finish first (same as floor-is-lava custom spawns)

	for ( int i = 0; i < file.customSpawnOrigins.len(); i++ )
	{
		array<string> classes = [ "info_spawnpoint_human", "info_spawnpoint_titan" ]
		foreach ( string cls in classes )
		{
			entity spawnpoint = CreateEntity( cls )
			spawnpoint.SetOrigin( file.customSpawnOrigins[i] )
			spawnpoint.SetAngles( file.customSpawnAngles[i] )
			spawnpoint.kv.ignoreGamemode = 1
			DispatchSpawn( spawnpoint )
		}
	}

	if ( file.wallModelOk )
	{
		PvPZone_BuildConfiguredWalls()
		PvPZone_ComputeBlockedSpawns()
	}

	PvPZone_LoadBoundaryFromConVar()
	if ( !file.hasBoundary )
	{
		printt( "[PvPZone] no play area for " + GetMapName() + " (walls only, nothing is lethal)" )
		return
	}

	file.fallMode = strip( GetConVarString( "pvpzone_boundary_mode" ) ).tolower() != "push"
	file.ceilingKill = GetConVarBool( "pvpzone_ceiling_kill" )
	printt( "[PvPZone] play area: " + file.boundary.poly.len() + " points, z " + int( file.boundary.minZ ) + " .. " + int( file.boundary.maxZ )
		+ ", outside = " + ( file.fallMode ? "fall death" : "push back" ) )

	foreach ( entity spawnpoint in GetEntArrayByClass_Expensive( "info_spawnpoint_human" ) )
	{
		if ( PvPZone_SpawnRule( spawnpoint, TEAM_UNASSIGNED ) )
			file.safeSpawns.append( spawnpoint.GetOrigin() )
	}
	foreach ( entity spawnpoint in GetEntArrayByClass_Expensive( "info_spawnpoint_titan" ) )
	{
		if ( PvPZone_SpawnRule( spawnpoint, TEAM_UNASSIGNED ) )
			file.titanSafeSpawns.append( spawnpoint.GetOrigin() )
	}
	if ( file.titanSafeSpawns.len() == 0 )
		file.titanSafeSpawns = clone file.safeSpawns
	printt( "[PvPZone] " + file.safeSpawns.len() + " pilot spawns inside the play area" )
	if ( file.safeSpawns.len() < 8 )
		printt( "[PvPZone] WARNING: few spawns inside the area, add more with pvpzone_spawn / PvPZone_AddSpawn" )

	if ( GetConVarBool( "pvpzone_cull_props" ) )
		PvPZone_CullOutside()

	thread PvPZone_Think()
}

// pvpzone_boundary_<map> = "x y z, x y z, x y z, ..." (corners in order, on the ground)
// floor  = lowest point - pvpzone_boundary_below, ceiling = highest point + pvpzone_boundary_above
void function PvPZone_LoadBoundaryFromConVar()
{
	string mapName = GetMapName()
	if ( !PvPZone_KnownMap( mapName ) )
		return
	string data = GetConVarString( "pvpzone_boundary_" + mapName )
	if ( strip( data ) == "" )
		return

	array<array<vector> > parsed = PvPZone_ParseSurfaces( data )
	if ( parsed.len() == 0 )
	{
		printt( "[PvPZone] pvpzone_boundary_" + mapName + " needs at least 3 points" )
		return
	}
	if ( parsed.len() > 1 )
		printt( "[PvPZone] pvpzone_boundary_" + mapName + " has several parts, only the first is used" )

	array<vector> pts = parsed[0]
	float zLow = pts[0].z
	float zHigh = pts[0].z
	foreach ( vector p in pts )
	{
		zLow = min( zLow, p.z )
		zHigh = max( zHigh, p.z )
	}

	file.boundary = PvPZone_MakeArea( pts, zLow - GetConVarFloat( "pvpzone_boundary_below" ), zHigh + GetConVarFloat( "pvpzone_boundary_above" ), 0.0 )
	file.hasBoundary = true
}

void function PvPZone_CullOutside()
{
	float margin = GetConVarFloat( "pvpzone_cull_margin" )
	vector mins = file.boundary.bbMins
	vector maxs = file.boundary.bbMaxs
	int removed = 0

	array<string> classes = [ "prop_dynamic", "prop_physics" ]
	foreach ( string cls in classes )
	{
		foreach ( entity ent in GetEntArrayByClass_Expensive( cls ) )
		{
			if ( !IsValid( ent ) || file.wallPieces.contains( ent ) )
				continue
			if ( ent.GetTargetName() != "" || ent.GetScriptName() != "" || IsValid( ent.GetParent() ) )
				continue

			vector o = ent.GetOrigin()
			if ( o.x < mins.x - margin || o.x > maxs.x + margin || o.y < mins.y - margin || o.y > maxs.y + margin )
			{
				ent.Destroy()
				removed++
			}
		}
	}
	printt( "[PvPZone] culled " + removed + " dynamic/physics props outside the area" )
}

void function PvPZone_SetFarZ( entity fogController )
{
	fogController.kv.farz = GetConVarFloat( "pvpzone_farz" )
}

// ===================================================================================
// Spawns
// ===================================================================================

bool function PvPZone_SpawnRule( entity spawnpoint, int team )
{
	if ( spawnpoint in file.blockedSpawns )
		return false

	if ( !file.hasBoundary )
		return true

	vector p = spawnpoint.GetOrigin() + < 0, 0, 8 >
	if ( !PvPZone_PointInArea( p, file.boundary ) )
		return false

	foreach ( PvPZoneArea zone in file.oobZones )
	{
		if ( PvPZone_PointInArea( p, zone ) )
			return false
	}
	return true
}

void function PvPZone_OnPlayerRespawned( entity player )
{
	if ( player in file.lastSafe )
		delete file.lastSafe[ player ]

	PvPZoneOOBState fresh
	if ( player in file.oob )
		file.oob[ player ] = fresh
	else
		file.oob[ player ] <- fresh
}

void function PvPZone_OnClientDisconnected( entity player )
{
	if ( player in file.lastSafe )
		delete file.lastSafe[ player ]
	if ( player in file.oob )
		delete file.oob[ player ]
	if ( player in file.lastWarn )
		delete file.lastWarn[ player ]
	if ( player in file.editPoints )
		delete file.editPoints[ player ]
}

void function PvPZone_TeleportToSafeSpawn( entity player )
{
	if ( file.safeSpawns.len() == 0 )
	{
		if ( !file.warnedNoSafeSpawn )
		{
			printt( "[PvPZone] WARNING: player outside the area but no spawn inside it to move them to" )
			file.warnedNoSafeSpawn = true
		}
		return
	}

	player.SetOrigin( file.safeSpawns.getrandom() )
	player.SetVelocity( < 0, 0, 0 > )
}

// ===================================================================================
// Script boundary + OOB zones (only when a boundary is configured)
// ===================================================================================

void function PvPZone_Think()
{
	for ( ;; )
	{
		WaitFrame()

		if ( GetGameState() >= eGameState.Postmatch )
			continue

		foreach ( entity player in GetPlayerArray() )
		{
			if ( !IsAlive( player ) )
				continue
			PvPZone_CheckPlayer( player )
		}

		// NPCs walk slower than players dash: every 10 frames is enough
		file.npcCheckFrame++
		if ( file.npcCheckFrame >= 10 )
		{
			file.npcCheckFrame = 0
			PvPZone_CheckNPCs()
		}
	}
}

void function PvPZone_CheckNPCs()
{
	foreach ( entity npc in GetNPCArray() )
	{
		if ( !IsAlive( npc ) || npc.Anim_IsActive() || IsValid( npc.GetParent() ) )
			continue
		if ( npc.IsTitan() && npc.e.isHotDropping )
			continue
		if ( PvPZone_PointInArea( npc.GetOrigin(), file.boundary ) )
			continue

		if ( npc.IsTitan() )
		{
			// auto-titans / titans that fell outside the area are moved back, not killed
			if ( file.titanSafeSpawns.len() > 0 )
			{
				npc.SetOrigin( file.titanSafeSpawns.getrandom() )
				npc.SetVelocity( < 0, 0, 0 > )
			}
		}
		else
		{
			npc.Die( svGlobal.worldspawn, svGlobal.worldspawn, { damageSourceId = eDamageSourceId.fall, scriptType = DF_INSTANT } )
		}
	}
}

// same as the map's own "fell out of the world" trigger: black screen + fall death
void function PvPZone_FallDeath( entity player )
{
	if ( player.IsGodMode() )
		return
	ScreenFade( player, 0, 0, 0, 255, 0.2, 1.0, FFADE_OUT | FFADE_PURGE )
	KillPlayer( player, eDamageSourceId.fall )
}

void function PvPZone_CheckPlayer( entity player )
{
	// scripted animations (executions, embark, rodeo mount) and the intro/evac dropship are skipped;
	// the check resumes the frame they end. Rodeo riders are parented to a titan and still checked.
	if ( player.Anim_IsActive() )
		return
	if ( player.IsNoclipping() ) // needs sv_cheats, same exemption as the native OOB system
		return
	entity parent = player.GetParent()
	if ( IsValid( parent ) && IsDropship( parent ) )
		return

	vector pos = player.GetOrigin()
	if ( PvPZone_PointInArea( pos, file.boundary ) )
	{
		if ( player in file.lastSafe )
			file.lastSafe[ player ] = pos
		else
			file.lastSafe[ player ] <- pos

		PvPZone_UpdateOOB( player, pos )
		return
	}

	if ( file.fallMode && player in file.lastSafe )
	{
		// above the ceiling but still over the area: not lethal unless pvpzone_ceiling_kill 1
		if ( !file.ceilingKill && pos.z > file.boundary.maxZ && PvPZone_InsideXY( pos, file.boundary ) )
		{
			vector vel = player.GetVelocity()
			if ( vel.z > 0.0 )
				player.SetVelocity( < vel.x, vel.y, 0.0 > )
			return
		}
		PvPZone_FallDeath( player )
		return
	}

	PvPZone_PushBack( player, pos )
}

void function PvPZone_PushBack( entity player, vector pos )
{
	if ( !( player in file.lastSafe ) )
	{
		PvPZone_TeleportToSafeSpawn( player )
		return
	}

	vector target = file.lastSafe[ player ]
	vector vel = player.GetVelocity()

	if ( pos.z > file.boundary.maxZ || pos.z < file.boundary.minZ )
	{
		if ( pos.z > file.boundary.maxZ && vel.z > 0.0 )
			vel = < vel.x, vel.y, 0.0 >
		else if ( pos.z < file.boundary.minZ && vel.z < 0.0 )
			vel = < vel.x, vel.y, 0.0 >
	}
	else
	{
		vector edge = PvPZone_ClosestEdgePoint2D( pos, file.boundary.poly )
		float nx = pos.x - edge.x
		float ny = pos.y - edge.y
		float len = sqrt( nx * nx + ny * ny )
		if ( len > 0.01 )
		{
			nx = nx / len
			ny = ny / len

			float outSpeed = vel.x * nx + vel.y * ny
			if ( outSpeed > 0.0 )
				vel = < vel.x - nx * outSpeed, vel.y - ny * outSpeed, vel.z >

			// next to walls the edge line may be inside a piece, so only slide along the edge when there are none
			vector candidate = < edge.x - nx * PVPZONE_PUSH_IN, edge.y - ny * PVPZONE_PUSH_IN, pos.z >
			if ( file.wallPieces.len() == 0 && PvPZone_PointInArea( candidate, file.boundary ) )
				target = candidate
		}
		else
		{
			vel = < 0.0, 0.0, vel.z >
		}
	}

	player.SetOrigin( target )
	player.SetVelocity( vel )
	PvPZone_WarnEdge( player )
}

void function PvPZone_WarnEdge( entity player )
{
	float now = Time()
	if ( player in file.lastWarn && now - file.lastWarn[ player ] < PVPZONE_WARN_INTERVAL )
		return

	if ( player in file.lastWarn )
		file.lastWarn[ player ] = now
	else
		file.lastWarn[ player ] <- now

	SendHudMessage( player, GetConVarString( "pvpzone_warn_text" ), -1, 0.35, 255, 90, 90, 255, 0.1, 1.0, 0.3 )
}

PvPZoneOOBState function PvPZone_GetOOBState( entity player )
{
	if ( !( player in file.oob ) )
	{
		PvPZoneOOBState s
		file.oob[ player ] <- s
	}
	return file.oob[ player ]
}

void function PvPZone_UpdateOOB( entity player, vector pos )
{
	if ( file.oobZones.len() == 0 )
		return

	float limit = 0.0
	foreach ( PvPZoneArea zone in file.oobZones )
	{
		if ( PvPZone_PointInArea( pos, zone ) )
		{
			limit = zone.oobTime
			break
		}
	}

	PvPZoneOOBState s = PvPZone_GetOOBState( player )
	float now = Time()

	if ( limit > 0.0 )
	{
		if ( !s.inZone )
		{
			float remaining = limit
			if ( s.remaining >= 0.0 )
				remaining = min( limit, s.remaining + ( now - s.leftAt ) )

			s.inZone = true
			s.deadline = now + remaining
			player.SetOutOfBoundsDeadTime( s.deadline ) // native "return to the battlefield" countdown
		}
		else if ( now >= s.deadline && GetGameState() == eGameState.Playing )
		{
			s.inZone = false
			s.remaining = -1.0
			player.SetOutOfBoundsDeadTime( 0.0 )
			player.Die( svGlobal.worldspawn, svGlobal.worldspawn, { scriptType = DF_INSTANT, damageSourceId = eDamageSourceId.outOfBounds } )
		}
	}
	else if ( s.inZone )
	{
		s.inZone = false
		s.remaining = max( 0.0, s.deadline - now )
		s.leftAt = now
		if ( !EntityIsOutOfBounds( player ) )
			player.SetOutOfBoundsDeadTime( 0.0 )
	}
}

// ===================================================================================
// Edit tools (pvpzone_edit 1)
// ===================================================================================

void function PvPZone_RegisterEditCommands()
{
	AddClientCommandCallback( "pvpzone_pos", PvPZone_CC_Pos )
	AddClientCommandCallback( "pvpzone_add", PvPZone_CC_Add )
	AddClientCommandCallback( "pvpzone_addpos", PvPZone_CC_AddPos )
	AddClientCommandCallback( "pvpzone_undo", PvPZone_CC_Undo )
	AddClientCommandCallback( "pvpzone_clear", PvPZone_CC_Clear )
	AddClientCommandCallback( "pvpzone_build", PvPZone_CC_Build )
	AddClientCommandCallback( "pvpzone_unbuild", PvPZone_CC_Unbuild )
	AddClientCommandCallback( "pvpzone_print", PvPZone_CC_Print )
	AddClientCommandCallback( "pvpzone_spawn", PvPZone_CC_Spawn )
	AddClientCommandCallback( "pvpzone_show", PvPZone_CC_Show )
	printt( "[PvPZone] edit commands enabled (pvpzone_edit 1). Turn this off on public servers." )
}

string function PvPZone_VecStr( vector v )
{
	return "< " + int( v.x ) + ", " + int( v.y ) + ", " + int( v.z ) + " >"
}

string function PvPZone_PointStr( vector v )
{
	return int( v.x ) + " " + int( v.y ) + " " + int( v.z )
}

void function PvPZone_Tell( entity player, string text )
{
	Chat_ServerPrivateMessage( player, text, false )
}

array<vector> function PvPZone_GetEditPoints( entity player )
{
	if ( !( player in file.editPoints ) )
	{
		array<vector> pts = []
		file.editPoints[ player ] <- pts
	}
	return file.editPoints[ player ]
}

void function PvPZone_AddEditPoint( entity player, vector p )
{
	array<vector> pts = PvPZone_GetEditPoints( player )
	pts.append( p )
	PvPZone_Tell( player, "point #" + pts.len() + "  " + PvPZone_PointStr( p ) )
	DebugDrawLine( p, p + < 0, 0, 64 >, 255, 220, 0, true, 30.0 )
	if ( pts.len() > 1 )
		DebugDrawLine( pts[ pts.len() - 2 ], p, 255, 220, 0, true, 30.0 )
}

bool function PvPZone_CC_Pos( entity player, array<string> args )
{
	PvPZone_Tell( player, "pos " + PvPZone_PointStr( player.GetOrigin() ) + "  yaw " + int( player.EyeAngles().y )
		+ "  inArea=" + ( PvPZone_IsPointInPlayArea( player.GetOrigin() ) ? "yes" : "no" ) )
	return true
}

// point where the crosshair hits the world (walls, floors, ceilings)
bool function PvPZone_CC_Add( entity player, array<string> args )
{
	vector eye = player.EyePosition()
	vector end = eye + AnglesToForward( player.EyeAngles() ) * 30000.0
	array<entity> ignore = [ player ]
	ignore.extend( file.wallPieces )
	ignore.extend( file.previewPieces )
	TraceResults tr = TraceLine( eye, end, ignore, TRACE_MASK_SOLID, TRACE_COLLISION_GROUP_NONE )
	if ( tr.fraction >= 1.0 )
	{
		PvPZone_Tell( player, "nothing under the crosshair, use pvpzone_addpos for a point in the air" )
		return true
	}
	PvPZone_AddEditPoint( player, tr.endPos )
	return true
}

// current eye position (use noclip to place points in the air)
bool function PvPZone_CC_AddPos( entity player, array<string> args )
{
	PvPZone_AddEditPoint( player, player.EyePosition() )
	return true
}

bool function PvPZone_CC_Undo( entity player, array<string> args )
{
	array<vector> pts = PvPZone_GetEditPoints( player )
	if ( pts.len() > 0 )
		pts.remove( pts.len() - 1 )
	PvPZone_Tell( player, pts.len() + " points left" )
	return true
}

bool function PvPZone_CC_Clear( entity player, array<string> args )
{
	PvPZone_GetEditPoints( player ).clear()
	PvPZone_Tell( player, "points cleared" )
	return true
}

// build the recorded points as a wall right now (preview, not saved)
bool function PvPZone_CC_Build( entity player, array<string> args )
{
	if ( !file.wallModelOk )
	{
		PvPZone_Tell( player, "walls are off (pvpzone_walls 0)" )
		return true
	}
	array<vector> pts = PvPZone_GetEditPoints( player )
	if ( pts.len() < 3 )
	{
		PvPZone_Tell( player, "need at least 3 points (have " + pts.len() + ")" )
		return true
	}
	int made = PvPZone_BuildSurface( pts, file.previewPieces, GetConVarInt( "pvpzone_wall_max_pieces" ) )
	PvPZone_Tell( player, "preview wall: " + made + " pieces (pvpzone_unbuild to remove all previews)" )
	return true
}

bool function PvPZone_CC_Unbuild( entity player, array<string> args )
{
	foreach ( entity piece in file.previewPieces )
	{
		if ( IsValid( piece ) )
			piece.Destroy()
	}
	file.previewPieces.clear()
	PvPZone_Tell( player, "preview walls removed" )
	return true
}

// pvpzone_print            -> wall surface string for mod.json
// pvpzone_print boundary   -> PvPZone_SetBoundary line (pvpzone_maps.nut)
// pvpzone_print oob [secs] -> PvPZone_AddOOBZone line (pvpzone_maps.nut)
bool function PvPZone_CC_Print( entity player, array<string> args )
{
	array<vector> pts = PvPZone_GetEditPoints( player )
	if ( pts.len() < 3 )
	{
		PvPZone_Tell( player, "need at least 3 points (have " + pts.len() + ")" )
		return true
	}

	string kind = args.len() > 0 ? args[0] : "wall"

	if ( kind == "wall" || kind == "boundary" )
	{
		string s = ""
		for ( int i = 0; i < pts.len(); i++ )
			s += ( i > 0 ? ", " : "" ) + PvPZone_PointStr( pts[i] )
		if ( kind == "wall" )
			printt( "[PvPZone] ---- surface for \"pvpzone_walls_" + GetMapName() + "\" in mod.json (separate surfaces with ;) ----" )
		else
			printt( "[PvPZone] ---- play area for \"pvpzone_boundary_" + GetMapName() + "\" in mod.json ----" )
		printt( s )
		PvPZone_Tell( player, kind + " (" + pts.len() + " points) printed to the console" )
		return true
	}

	float zLow = pts[0].z
	float zHigh = pts[0].z
	string arr = "[ "
	for ( int i = 0; i < pts.len(); i++ )
	{
		zLow = min( zLow, pts[i].z )
		zHigh = max( zHigh, pts[i].z )
		arr += ( i > 0 ? ", " : "" ) + "< " + int( pts[i].x ) + ", " + int( pts[i].y ) + ", 0 >"
	}
	arr += " ]"

	string line
	if ( kind == "oob" )
	{
		float seconds = args.len() > 1 ? args[1].tofloat() : 5.0
		line = "PvPZone_AddOOBZone( \"" + GetMapName() + "\", " + arr + ", " + int( zLow - 128 ) + ", " + int( zHigh + 1024 ) + ", " + seconds + " )"
	}
	else
	{
		line = "PvPZone_SetBoundary( \"" + GetMapName() + "\", " + arr + ", " + int( zLow - 512 ) + ", " + int( zHigh + 2048 ) + " )"
	}

	printt( "[PvPZone] ---- copy into pvpzone_maps.nut ----" )
	printt( line )
	PvPZone_Tell( player, kind + " (" + pts.len() + " points) printed to the console" )
	return true
}

bool function PvPZone_CC_Spawn( entity player, array<string> args )
{
	vector o = player.GetOrigin()
	printt( "PvPZone_AddSpawn( \"" + GetMapName() + "\", " + PvPZone_VecStr( o ) + ", < 0, " + int( player.EyeAngles().y ) + ", 0 > )" )
	PvPZone_Tell( player, "spawn printed to console " + PvPZone_PointStr( o ) )
	return true
}

bool function PvPZone_CC_Show( entity player, array<string> args )
{
	float z = player.GetOrigin().z + 16
	if ( file.hasBoundary )
		PvPZone_DrawFlatPoly( file.boundary.poly, z, 0, 255, 0 )
	foreach ( PvPZoneArea zone in file.oobZones )
		PvPZone_DrawFlatPoly( zone.poly, z, 255, 0, 0 )

	array<vector> pts = PvPZone_GetEditPoints( player )
	for ( int i = 0; i < pts.len(); i++ )
		DebugDrawLine( pts[i], pts[ ( i + 1 ) % pts.len() ], 255, 220, 0, true, 15.0 )

	PvPZone_Tell( player, "drawing for 15s (debug overlay, host only)" )
	return true
}

void function PvPZone_DrawFlatPoly( array<vector> poly, float z, int r, int g, int b )
{
	int n = poly.len()
	for ( int i = 0; i < n; i++ )
	{
		vector a = < poly[i].x, poly[i].y, z >
		vector c = < poly[ ( i + 1 ) % n ].x, poly[ ( i + 1 ) % n ].y, z >
		DebugDrawLine( a, c, r, g, b, true, 15.0 )
		DebugDrawLine( a, a + < 0, 0, 256 >, r, g, b, true, 15.0 )
	}
}
