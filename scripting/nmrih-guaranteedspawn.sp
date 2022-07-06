#pragma semicolon 1
#pragma newdecls required

#include <dhooks>
#include <guaranteedspawn>
#include <nmr_instructor>
#include <sdkhooks>
#include <sdktools>
#include <sourcemod>

#define PREFIX "[Guaranteed Spawn] "
#define PLUGIN_VERSION "1.0.9"
#define PLUGIN_DESCRIPTION "Grants a spawn to late joiners"

#define INET6_ADDRSTRLEN 46
#define NMR_MAXPLAYERS   9

#define STATE_ACTIVE 0

#define OBS_MODE_IN_EYE 4
#define OBS_MODE_CHASE  5
#define OBS_MODE_POI    6

public Plugin myinfo =
{
	name        = "[NMRiH] Guaranteed Spawn",
	author      = "Dysphie",
	description = PLUGIN_DESCRIPTION,
	version     = PLUGIN_VERSION,
	url         = "https://github.com/dysphie/nmrih-guaranteedspawn"
};

Handle hintTimer[NMR_MAXPLAYERS + 1];

StringMap ipSpawned;
StringMap steamSpawned;
bool      indexSpawned[NMR_MAXPLAYERS + 1];
bool      joinedGame[NMR_MAXPLAYERS + 1];
int       offs_SpawnEnabled = -1;
ArrayList spawnpoints;

GlobalForward spawnFwd;

int         spawningPlayer = -1;
DynamicHook fnGetPlayerSpawnSpot;
Handle      sdkSpawnPlayer;
Handle      sdkStateTrans;

ConVar cvNearby;
ConVar cvStatic;
ConVar cvCheckSteamID;
ConVar cvCheckIP;

public void OnPluginStart()
{
	LoadTranslations("guaranteedspawn.phrases");
	DoGamedataStuff();

	ipSpawned    = new StringMap();
	steamSpawned = new StringMap();
	spawnpoints  = new ArrayList();

	cvStatic = CreateConVar("sm_gspawn_allow_checkpoint", "1");
	cvNearby = CreateConVar("sm_gspawn_allow_nearby", "1");
	
	cvCheckSteamID = CreateConVar("sm_gspawn_remember_steamid", "1", "Track players by SteamID64");
	cvCheckIP = CreateConVar("sm_gspawn_remember_ip", "1", "Track players by IP");
	
	CreateConVar("guaranteedspawn_version", PLUGIN_VERSION, PLUGIN_DESCRIPTION,
    	FCVAR_SPONLY|FCVAR_NOTIFY|FCVAR_DONTRECORD);


	HookEvent("nmrih_reset_map", Event_MapReset, EventHookMode_PostNoCopy);
	HookEvent("player_spawn", Event_PlayerSpawned);

	AddCommandListener(OnSpecUpdate, "spec_next");
	AddCommandListener(OnSpecUpdate, "spec_prev");
	AddCommandListener(OnSpecUpdate, "spec_mode");
	AddCommandListener(Command_JoinGame, "joingame");

	AutoExecConfig(true, "plugin.guaranteedspawn");

	spawnFwd = new GlobalForward("GS_OnGuaranteedSpawn", ET_Event, Param_Cell, Param_Cell);
}

void Event_PlayerSpawned(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));

	// Ignore false-positives
	if (!client || !NMRiH_IsPlayerAlive(client))
	{
		return;
	}

	// This client can't force-spawn anymore for the duration of the round
	StopWaitingForSpawn(client);
	RememberSpawned(client);
}

void StopWaitingForSpawn(int client)
{
	delete hintTimer[client];
	RemoveInstructorHint(client, "guaranteedspawn");
}

void DoGamedataStuff()
{
	GameData gamedata = new GameData("guaranteedspawn.games");
	if (!gamedata) {
		SetFailState("Failed to find gamedata/guaranteedspawns.games.txt");
	}

	StartPrepSDKCall(SDKCall_Player);
	PrepSDKCall_SetFromConf(gamedata, SDKConf_Virtual, "CNMRiH_Player::Spawn");
	sdkSpawnPlayer = EndPrepSDKCall();
	if (!sdkSpawnPlayer)
	{
		SetFailState("Failed to set up SDKCall for CNMRiH_Player::Spawn");
	}

	StartPrepSDKCall(SDKCall_Player);
	PrepSDKCall_SetFromConf(gamedata, SDKConf_Signature, "CSDKPlayer::State_Transition");
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	sdkStateTrans = EndPrepSDKCall();
	if (!sdkStateTrans)
		SetFailState("Failed to set up SDKCall for CSDKPlayer::State_Transition");

	offs_SpawnEnabled = gamedata.GetOffset("CNMRiH_PlayerSpawn::m_bEnabled");
	if (offs_SpawnEnabled == -1)
	{
		SetFailState("Failed to get offset to CNMRiH_PlayerSpawn::m_bEnabled");
	}

	int offs_GetPlayerSpawnSpot = gamedata.GetOffset("CGameRules::GetPlayerSpawnSpot");
	if (offs_GetPlayerSpawnSpot == -1)
	{
		SetFailState("Failed to get offset to CGameRules::GetPlayerSpawnSpot");
	}

	fnGetPlayerSpawnSpot = new DynamicHook(offs_GetPlayerSpawnSpot, HookType_GameRules, ReturnType_CBaseEntity, ThisPointer_Ignore);
	fnGetPlayerSpawnSpot.AddParam(HookParamType_CBaseEntity);    // CBasePlayer *, player

	delete gamedata;
}

public void OnMapStart()
{
	fnGetPlayerSpawnSpot.HookGamerules(Hook_Pre, Detour_GetPlayerSpawnSpot);
}

public void OnMapEnd()
{
	for (int i = 1; i < sizeof(hintTimer); i++)
	{
		delete hintTimer[i];
	}
}

/**
 * CBasePlayer::Spawn calls CGameRules::GetPlayerSpawnSpot and if it returns 0
 * it sends the player back to observer mode. We bypass that by giving it a valid entity.
 * It's not used so we can just pass it any valid entity, like the player
 */
MRESReturn Detour_GetPlayerSpawnSpot(DHookReturn ret)
{
	if (spawningPlayer != -1)
	{
		ret.Value = spawningPlayer;
		return MRES_Supercede;
	}
	return MRES_Ignored;
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if (StrEqual(classname, "info_player_nmrih"))
	{
		spawnpoints.Push(EntIndexToEntRef(entity));
	}
}

int GetAvailableSpawnpoint(int client = -1)
{
	int maxSpawnpoints = spawnpoints.Length;
	if (maxSpawnpoints == 0)
	{
		return -1;
	}

	float closestDist       = 9999999.0;
	int   closestSpawnpoint = -1;

	// Iterate backwards
	for (int i = maxSpawnpoints - 1; i >= 0; i--)
	{
		int entref = spawnpoints.Get(i);
		int ent    = EntRefToEntIndex(entref);
		if (ent == -1)
		{
			spawnpoints.Erase(i);
			continue;
		}

		if (!IsSpawnpointEnabled(ent)) {
			continue;
		}

		// If no client is specified, we can use any spawnpoint
		if (client == -1)
		{
			return ent;
		}

		// Else find the spawnpoint closest to a teammate
		for (int teammate = 1; teammate <= MaxClients; teammate++)
		{
			if (teammate == client || !IsClientInGame(teammate) || !NMRiH_IsPlayerAlive(teammate))
			{
				continue;
			}

			float dist = DistanceBetweenEnts(ent, teammate);
			if (dist < closestDist)
			{
				closestDist       = dist;
				closestSpawnpoint = ent;
			}
		}
	}

	return closestSpawnpoint;
}

void Event_MapReset(Event event, const char[] name, bool silent)
{
	ClearSpawnHistory();
}

void ClearSpawnHistory()
{
	steamSpawned.Clear();
	ipSpawned.Clear();
	for (int i = 1; i <= MaxClients; i++)
	{
		indexSpawned[i] = false;
	}
}

public void OnClientDisconnect(int client)
{
	indexSpawned[client] = false;
	joinedGame[client]   = false;
	delete hintTimer[client];
}

void RememberSpawned(int client)
{
	indexSpawned[client] = true;

	char steamID[21];
	if (GetClientAuthId(client, AuthId_SteamID64, steamID, sizeof(steamID)))
	{
		steamSpawned.SetValue(steamID, true);
	}

	char ip[16];
	if (GetClientIP(client, ip, sizeof(ip)))
	{
		ipSpawned.SetValue(ip, true);
	}
}

bool NMRiH_IsPlayerAlive(int client)
{
	return IsPlayerAlive(client) && GetEntProp(client, Prop_Send, "m_iPlayerState") == STATE_ACTIVE;
}

bool IsSpawnpointEnabled(int spawnpoint)
{
	int val = GetEntData(spawnpoint, offs_SpawnEnabled, 1);
	if (val != 1 && val != 0)
	{
		LogError(PREFIX... "Bad value for CNMRiH_PlayerSpawn::m_bEnabled. Expected 1 or 0, got %d", val);
	}

	return val == 1;
}

void UpdateHint(int client)
{
	if (!CouldSpawnThisRound(client))
	{
		return;
	}

	int target = GetBestSpawnTarget(client, false);
	if (target != -1)
	{
		if (!IsValidClient(target))
		{
			ShowRespawnHint(client, "%t", "Respawn At Checkpoint");
		}
		else
		{
			ShowRespawnHint(client, "%t", "Respawn At Teammate", target);
		}
	}
}

void ShowRespawnHint(int client, const char[] format, any...)
{
	SetGlobalTransTarget(client);

	char buffer[512];
	VFormat(buffer, sizeof(buffer), format, 3);

	SendInstructorHint(client,
	                   "guaranteedspawn", "guaranteedspawn", 0, 0, 2,
	                   ICON_BINDING, ICON_BINDING,
	                   buffer, buffer, 255, 255, 255,
	                   0.0, 0.0, 0, "+use", true, false, false, false, "", 255);
}

Action Command_JoinGame(int client, const char[] command, int argc)
{
	// Command listeners can contain unconnected player indexes
	// It can also fire multiple times, only check once
	if (!IsValidClient(client) || joinedGame[client] || !CouldSpawnThisRound(client))
	{
		return Plugin_Continue;
	}

	joinedGame[client] = true;
	BeginWaitingForSpawn(client);
	return Plugin_Continue;
}

Action OnSpecUpdate(int client, const char[] command, int argc)
{
	if (CouldSpawnThisRound(client))
	{
		RequestFrame(Frame_UpdateHintForClient, GetClientSerial(client));
	}

	return Plugin_Continue;
}

void Frame_UpdateHintForClient(int serial)
{
	int client = GetClientFromSerial(serial);
	if (client)
	{
		UpdateHint(client);
	}
}

int GetObserverTarget(int client)
{
	int obsMode = GetEntProp(client, Prop_Send, "m_iObserverMode");
	if (obsMode == OBS_MODE_IN_EYE || obsMode == OBS_MODE_CHASE || obsMode == OBS_MODE_POI)
	{
		int target = GetEntPropEnt(client, Prop_Send, "m_hObserverTarget");
		if (target != client && 0 < target <= MaxClients && NMRiH_IsPlayerAlive(target))
		{
			return target;
		}
	}
	return -1;
}

public Action OnPlayerRunCmd(int client, int& buttons, int& impulse, float vel[3], float angles[3], int& weapon, int& subtype, int& cmdnum, int& tickcount, int& seed, int mouse[2])
{
	if ((buttons & IN_USE) && CouldSpawnThisRound(client))
	{
		int target = GetBestSpawnTarget(client, false);
		if (target == -1) {
			return Plugin_Continue;
		}
		
		if (!IsValidClient(target))
		{
			SpawnAtCheckpoint(client);
		}
		else
		{
			SpawnAtPlayer(client, target);
		}
	}

	return Plugin_Continue;
}

int GetBestSpawnTarget(int client, bool distCheck)
{
	int obsTarget = GetObserverTarget(client);
	bool nearbyAllowed = cvNearby.BoolValue;

	// If player is spectating a player, spawn near that player
	if (obsTarget != -1 && nearbyAllowed)
	{
		return obsTarget;
	}

	// Player is freeroaming or nearby spawning is disabled
	// If checkpoints are enabled, spawn near the closest checkpoint
	if (cvStatic.BoolValue)
	{
		int spawnpoint = GetAvailableSpawnpoint(distCheck ? client : -1);
		if (spawnpoint != -1)
		{
			return spawnpoint;
		}
	}

	// No checkpoints are available
	// If nearby spawning is enabled, pick a random player as target
	// TODO: Pick the closest?
	if (nearbyAllowed)
	{
		return GetRandomPlayer(client);
	}

	return -1;
}

int GetRandomPlayer(int excludePlayer) 
{
    int[] players = new int[MaxClients];
    int count = 0;
    for (int i = 1; i <= MaxClients; ++i) 
	{
        if (i != excludePlayer && IsClientInGame(i) && NMRiH_IsPlayerAlive(i)) 
		{
            players[count] = i;
            ++count;
        }
    }
    if (count) 
	{
        return players[GetRandomInt(0, count - 1)];
    }
    return -1;
}

void ForceSpawn(int client, float origin[3], float angles[3], GSMethod type)
{
	// Let other plugins know that we are about to force spawn
	Action result;
	Call_StartForward(spawnFwd);
	Call_PushCell(client);
	Call_PushCell(type);
	Call_Finish(result);

	// If everyone's okay with it, do it
	if (result == Plugin_Continue)
	{
		spawningPlayer = client;
		SDKCall(sdkStateTrans, client, STATE_ACTIVE);
		SDKCall(sdkSpawnPlayer, client);
		spawningPlayer = -1;
		TeleportEntity(client, origin, angles, NULL_VECTOR);
	}
}

void SpawnAtCheckpoint(int client)
{
	int closestSpawn = GetAvailableSpawnpoint(client);
	if (closestSpawn == -1)
	{
		// We should never get here
		return;
	}

	float pos[3], ang[3];
	GetEntityPosition(closestSpawn, pos);
	GetEntityRotation(closestSpawn, ang);
	ForceSpawn(client, pos, ang, GSMethod_Checkpoint);
}

void SpawnAtPlayer(int client, int target)
{
	// TODO: Currently it just respawns inside the other player
	float pos[3], ang[3];
	GetClientAbsOrigin(target, pos);
	GetClientAbsAngles(target, ang);
	ForceSpawn(client, pos, ang, GSMethod_Nearby);
}

bool CouldSpawnThisRound(int client)
{
	if (indexSpawned[client])
	{
		return false;
	}

	if (!IsRoundOnGoing())
	{
		return false;
	} 
	
	if (NMRiH_IsPlayerAlive(client))
	{
		return false;
	}

	if (cvCheckSteamID.BoolValue)
	{
		char steamId[MAX_AUTHID_LENGTH];
		if (!GetClientAuthId(client, AuthId_SteamID64, steamId, sizeof(steamId)))
		{
			// Players without a SteamID are considered spawned
			return false;
		}

		bool didSpawn;
		if (steamSpawned.GetValue(steamId, didSpawn) && didSpawn)
		{
			return false;
		}
	}

	if (cvCheckIP.BoolValue)
	{
		char ip[INET6_ADDRSTRLEN];
		if (!GetClientIP(client, ip, sizeof(ip)))
		{
			// Players without an IP are considered spawned
			return false;
		}

		bool didSpawn;
		if (ipSpawned.GetValue(ip, didSpawn) && didSpawn)
		{
			return false;
		}
	}

	return true;
}

bool IsRoundOnGoing()
{
	static int STATE_ONGOING = 3;
	return GameRules_GetProp("_roundState") == STATE_ONGOING;
}

bool IsValidClient(int client)
{
	return 0 < client <= MaxClients && IsClientInGame(client);
}

void BeginWaitingForSpawn(int client)
{
	UpdateHint(client);

	delete hintTimer[client];
	hintTimer[client] = CreateTimer(1.0, Timer_UpdateHint, GetClientSerial(client), TIMER_REPEAT);
}

Action Timer_UpdateHint(Handle timer, int clientSerial)
{
	int client = GetClientFromSerial(clientSerial);
	if (!IsValidClient(client))
	{
		return Plugin_Stop;
	}

	if (!CouldSpawnThisRound(client))
	{
		return Plugin_Continue;
	}

	UpdateHint(client);
	return Plugin_Continue;
}

float DistanceBetweenEnts(int a, int b)
{
	float posA[3], posB[3];
	GetEntityPosition(a, posA);
	GetEntityPosition(b, posB);

	return GetVectorDistance(posA, posB);
}

void GetEntityPosition(int entity, float pos[3])
{
	GetEntPropVector(entity, Prop_Data, "m_vecAbsOrigin", pos);
}

void GetEntityRotation(int entity, float angles[3])
{
	GetEntPropVector(entity, Prop_Data, "m_angAbsRotation", angles);
}
