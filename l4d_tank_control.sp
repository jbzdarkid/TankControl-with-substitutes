#pragma semicolon 1;

#include <sourcemod>
#include <sdktools>
#include <l4d2util>
#include <l4d2_direct>
#include <left4downtown>
#include <colors>

#define IS_VALID_CLIENT(%1)     (%1 > 0 && %1 <= MaxClients)
#define IS_INFECTED(%1)         (GetClientTeam(%1) == 3)
#define IS_VALID_INGAME(%1)     (IS_VALID_CLIENT(%1) && IsClientInGame(%1))
#define IS_VALID_INFECTED(%1)   (IS_VALID_INGAME(%1) && IS_INFECTED(%1))

new Handle:h_whosHadTank;
new String:queuedTankSteamId[64];
new Handle:hTankPrint;
new Handle:hTankDebug;
// A list of substitutions that have occured.
// [substitute slot][(player who left,player who replaced them)] = steamid
new String:substitutes[8][2][64];
new bool:gameStarted;

public Plugin:myinfo =
{
    name = "L4D2 Tank Control",
    author = "arti, darkid",
    description = "Distributes the role of the tank evenly throughout the team",
    version = "0.0.16+",
    url = "https://github.com/jbzdarkid/TankControl-with-substitutes"
}

enum L4D2Team
{
    L4D2Team_None = 0,
    L4D2Team_Spectator,
    L4D2Team_Survivor,
    L4D2Team_Infected
}

public Action:Debug(client, args) {
    for (new i=0; i<8; i++) {
        PrintToChat(client, "Slot %d: '%s' -> '%s'", i, substitutes[i][0], substitutes[i][1]);
    }
}

public OnPluginStart()
{
    RegConsoleCmd("tc_debug_subs", Debug, "Debug substitute array to chat");
    
    // Load translations (for targeting player)
    LoadTranslations("common.phrases");
    
    // Event hooks
    HookEvent("player_left_start_area", PlayerLeftStartArea);
    HookEvent("round_end", RoundEnd);
    HookEvent("player_team", PlayerTeam);
    HookEvent("tank_killed", TankKilled);
    HookEvent("player_death", PlayerDeath, EventHookMode_Post);
    
    // Initialise the tank arrays/data values
    h_whosHadTank = CreateArray(64);
    
    // Register the boss commands
    RegConsoleCmd("sm_tank", PrintTank, "Shows who is becoming the tank.");
    RegConsoleCmd("sm_boss", PrintTank, "Shows who is becoming the tank.");
    RegConsoleCmd("sm_witch", PrintTank, "Shows who is becoming the tank.");
    
    // Admin commands
    RegAdminCmd("sm_tankshuffle", TankShuffle, ADMFLAG_SLAY, "Re-picks at random someone to become tank.");
    RegAdminCmd("sm_givetank", GiveTank, ADMFLAG_SLAY, "Gives the tank to a selected player");
    
    // Cvars
    hTankPrint = CreateConVar("tankcontrol_print_all", "1", "Who gets to see who will become the tank? (0 = Infected, 1 = Everyone)", FCVAR_PLUGIN);
    hTankDebug = CreateConVar("tankcontrol_debug", "1", "Whether or not to debug to console", FCVAR_PLUGIN);

}

/**
 *  When the tank disconnects, choose another one.
 */
 
public OnClientDisconnect(client)
{
    decl String:tmpSteamId[64];
    
    if (client)
    {
        GetClientAuthString(client, tmpSteamId, sizeof(tmpSteamId));
        if (strcmp(queuedTankSteamId, tmpSteamId) == 0)
        {
            chooseTank();
            outputTankToAll();
        }
    }
}

/**
 * When a new game starts, reset the tank pool.
 */
 
public OnRoundStart()
{
    CreateTimer(10.0, newGame);
}

public Action:newGame(Handle:timer)
{
    new teamAScore = L4D2Direct_GetVSCampaignScore(0);
    new teamBScore = L4D2Direct_GetVSCampaignScore(1);
    gameStarted = false; // Don't track substitutes until the teams are picked. i.e. someone exits saferoom.
    
    // If it's a new game, reset the tank pool and substitute list.
    if (teamAScore == 0 && teamBScore == 0)
    {
        h_whosHadTank = CreateArray(64);
        queuedTankSteamId = "";
        if (GetConVarBool(hTankDebug)) PrintToConsoleAll("[TC-S] New game, resetting substitutes.");
        for (new i = 0; i < 8; i++) {
            substitutes[i][0] = "";
            substitutes[i][1] = "";
        }
    }
}

/**
 * When the round ends, reset the active tank.
 */
 
public RoundEnd(Handle:event, const String:name[], bool:dontBroadcast)
{
    queuedTankSteamId = "";
}

/**
 * When a player leaves the start area, choose a tank and output to all.
 */
 
public PlayerLeftStartArea(Handle:event, const String:name[], bool:dontBroadcast)
{
    gameStarted = true;
    if (GetConVarBool(hTankDebug)) PrintToConsoleAll("[TC-S] Round went live, allowing substitutions.");
    chooseTank();
    outputTankToAll();
}

/**
 * When the queued tank switches teams, choose a new one
 * When a player switches teams, track for substitutions.
 */
 
public PlayerTeam(Handle:event, const String:name[], bool:dontBroadcast)
{
    if (!gameStarted) return;
    new client = GetClientOfUserId(GetEventInt(event, "userid"));
    if (client <= 0 || client > MaxClients) return;
    new L4D2Team:newTeam = L4D2Team:GetEventInt(event, "team");
    new L4D2Team:oldTeam = L4D2Team:GetEventInt(event, "oldteam");
    decl String:steamId[64];
    GetClientAuthString(client, steamId, sizeof(steamId));
    if (strcmp(steamId, "BOT") == 0) return; // Ignore bots
    if (GetConVarBool(hTankDebug)) PrintToConsoleAll("[TC-S] Player %s changed from team %d to team %d", steamId, oldTeam, newTeam);
    
    if ((newTeam == L4D2Team:L4D2Team_Infected || newTeam == L4D2Team:L4D2Team_Survivor)
        && (oldTeam == L4D2Team:L4D2Team_None || oldTeam == L4D2Team:L4D2Team_Spectator)) {
        PlayerJoin(steamId);
    } else if ((newTeam == L4D2Team:L4D2Team_None || newTeam == L4D2Team:L4D2Team_Spectator)
    && (oldTeam == L4D2Team:L4D2Team_Infected || oldTeam == L4D2Team:L4D2Team_Survivor)) {
        PlayerLeave(steamId);
    }
}

// When a player joins, check to see if they are a substitute, a new player, or an old player rejoining.
PlayerJoin(String:steamId[64]) {
    new index = -1;
    new firstOpen = -1;
    for (new i=0; i<8; i++) {
        if (firstOpen == -1 && strcmp(substitutes[i][0], "") != 0 && strcmp(substitutes[i][1], "") == 0) {
            firstOpen = i;
        }
        if (strcmp(substitutes[i][0], steamId) == 0) {
            index = i;
        }
    }
    
    // No available substitute spot. This may be thrown incorrectly at the start of game. ###
    if (firstOpen == -1) {
        if (GetConVarBool(hTankDebug)) PrintToConsoleAll("[TC-S] ERROR: Joining player %s couldn't find a substitute spot.", steamId);
    // The player has not played in this game, so sub them into the first sub spot.
    } else if (index == -1) {
        substitutes[firstOpen][1] = steamId;
        if (GetConVarBool(hTankDebug)) PrintToConsoleAll("[TC-S] Player %s substituting for player %s.", steamId, substitutes[firstOpen][0]);
    // The player leaves and rejoins (crash, e.g.)
    } else if (strcmp(substitutes[index][1], "") == 0) {
        substitutes[index][0] = "";
        if (GetConVarBool(hTankDebug)) PrintToConsoleAll("[TC-S] Player %s has rejoined.", steamId);
    // Player A leaves, is subbed for by player B, then player C leaves, and player A rejoins. We simplify by saying player B is substituting for player C.
    // substitutes[index] = [A , B]  substitutes[firstOpen] = [C, ""]
    // becomes:
    // substitutes[index] = ["", ""] substitutes[firstOpen] = [C, B] 
    } else {
        substitutes[firstOpen][1] = substitutes[index][1];
        substitutes[index][0] = "";
        substitutes[index][1] = "";
        if (GetConVarBool(hTankDebug)) PrintToConsoleAll("[TC-S] Player %s has rejoined, cleaning substitutions.", steamId);
    }
}

// When a player leaves the game, prepare for a substitute player to arrive.
PlayerLeave(String:steamId[64]) {
    new firstOpen = -1;
    new index = -1;
    for (new i=0; i<8; i++) {
        if (firstOpen == -1 && strcmp(substitutes[i][0], "") == 0 && strcmp(substitutes[i][1], "") == 0) {
            firstOpen = i;
        }
        if (strcmp(substitutes[i][1], steamId) == 0) {
            index = i;
        }
    }

    // No available substitute spot. This is an error.
    if (firstOpen == -1) {
        if (GetConVarBool(hTankDebug)) PrintToConsoleAll("[TC-S] ERROR: Leaving player %s couldn't find substitute spot.", steamId);
    // Substitute spot available, and player not already listed. One of the original players is leaving.
    } else if (index == -1) {
        substitutes[firstOpen][0] = steamId;
        if (GetConVarBool(hTankDebug)) PrintToConsoleAll("[TC-S] Player %s leaving, opening substitute spot %d.", steamId, firstOpen);
    // Player already listed (i.e. was substitute), so re-open substitute spot.
    } else {
        substitutes[index][1] = "";
        if (GetConVarBool(hTankDebug)) PrintToConsoleAll("[TC-S] Substitute player %s leaving, re-opening spot %d.", steamId, index);
    }

    // If the player was tank, choose a new tank.
    if (strcmp(queuedTankSteamId, steamId) == 0)
    {
        chooseTank();
        outputTankToAll();
    }
}

/**
 * When the tank dies, choose a new player to become tank (for finales)
 */
 
public PlayerDeath(Handle:event, const String:name[], bool:dontBroadcast)
{
    new zombieClass = 0;
    new victimId = GetEventInt(event, "userid");
    new victim = GetClientOfUserId(victimId);
    
    if (victimId && IsClientInGame(victim))
    {
        zombieClass = GetEntProp(victim, Prop_Send, "m_zombieClass");
        if (zombieClass == 8)
        {
            if (GetConVarBool(hTankDebug)) PrintToConsoleAll("[TC] Tank died(1), choosing a new tank");
            chooseTank();
        }
    }
}

public TankKilled(Handle:event, const String:name[], bool:dontBroadcast)
{
    if (GetConVarBool(hTankDebug)) PrintToConsoleAll("[TC] Tank died(2), choosing a new tank");
    chooseTank();
}


/**
 * When a player wants to find out who's becoming tank,
 * output to them.
 */
 
public Action:PrintTank(client, args)
{
    new tankClientId;
    decl String:tankClientName[128];
    
    // Only output if we have a queued tank
    if (! strcmp(queuedTankSteamId, ""))
    {
        return Plugin_Handled;
    }
    
    tankClientId = getInfectedPlayerBySteamId(queuedTankSteamId);
    if (tankClientId != -1)
    {
        GetClientName(tankClientId, tankClientName, sizeof(tankClientName));
        
        // If on infected, print to entire team
        if (L4D2Team:GetClientTeam(client) == L4D2Team:L4D2Team_Infected)
        {
            for (new i = 1; i <= MaxClients; i++)
            {
                if (IsClientConnected(i) && IsClientInGame(i) && ! IsFakeClient(i) && L4D2Team:GetClientTeam(i) == L4D2Team:L4D2Team_Infected)
                {
                    CPrintToChat(i, "{olive}%s {default}will become the tank!", tankClientName);
                }
            }
        }
        
        // Otherwise just print to the player who typed the command
        else if (GetConVarBool(hTankPrint))
        {
            CPrintToChat(client, "{olive}%s {default}will become the tank!", tankClientName);
        }
    }
    
    return Plugin_Handled;
}

/**
 * Shuffle the tank (randomly give to another player in
 * the pool.)
 */
 
public Action:TankShuffle(client, args)
{
    chooseTank();
    outputTankToAll();
    
    return Plugin_Handled;
}

/**
 * Give the tank to a specific player.
 */
 
public Action:GiveTank(client, args)
{
    // Who are we targeting?
    new String:arg1[32];
    GetCmdArg(1, arg1, sizeof(arg1));
    
    // Try and find a matching player
    new target = FindTarget(client, arg1);
    if (target == -1)
    {
        return Plugin_Handled;
    }
    
    // Get the players name
    new String:name[MAX_NAME_LENGTH];
    GetClientName(target, name, sizeof(name));
    
    // Set the tank
    if (IsClientConnected(target) && IsClientInGame(target) && ! IsFakeClient(target))
    {
        // Checking if on our desired team
        if (L4D2Team:GetClientTeam(target) != L4D2Team:L4D2Team_Infected)
        {
            CPrintToChatAll("{olive}[SM] {default}%s not on infected. Unable to give tank", name);
            return Plugin_Handled;
        }
        
        decl String:steamId[64];
        GetClientAuthString(target, steamId, sizeof(steamId));

        queuedTankSteamId = steamId;
        outputTankToAll();
    }
    
    return Plugin_Handled;
}

/**
 * Selects a player on the infected team from random who hasn't been
 * tank and gives it to them.
 *
 * With substitutes, we select from the original 4 players. If any of them haven't had tank, we give it to them, or their substitute.
 * If all 4 have, we look through the substitutes.
 * If all 4 original players and substitutes have had tank, we give all players equal odds at the next tank.
 */
 
public chooseTank()
{
    // Create our pool of players to choose from
    new Handle:infectedPool = teamSteamIds(L4D2Team_Infected, true);
    
    // If there is nobody on the infected team, return (otherwise we'd be stuck trying to select forever)
    if (GetArraySize(infectedPool) == 0)
        return;
    
    // Remove players who've already had tank from the pool.
    infectedPool = removeTanksFromPool(infectedPool, h_whosHadTank);
    
    // If the infected pool is empty, then consider substitutes.
    if (GetArraySize(infectedPool) == 0)
    {
        infectedPool = teamSteamIds(L4D2Team_Infected, false);
        infectedPool = removeTanksFromPool(infectedPool, h_whosHadTank);
        // If the pool is still empty, all substitutes have had tank. Wipe the substitutes and start over.
        if (GetArraySize(infectedPool) == 0)
        {
            new Handle:infectedSubs = teamSteamIds(L4D2Team_Infected, false);
            h_whosHadTank = removeTanksFromPool(h_whosHadTank, infectedSubs);
            h_whosHadTank = removeTanksFromPool(h_whosHadTank, teamSteamIds(L4D2Team_Infected, true));
            for (new i=0; i<64; i++) {
                new String:steamId[64];
                GetArrayString(infectedSubs, i, steamId, sizeof(steamId));
                for (new j=0; j<8; j++) {
                    if (strcmp(substitutes[j][1], steamId) == 0) {
                        substitutes[j][0] = "";
                        substitutes[j][1] = "";
                        break;
                    }
                }
            }
            chooseTank();
            return;
        }
    }
    
    // Select a random person to become tank
    new rndIndex = GetRandomInt(0, GetArraySize(infectedPool) - 1);
    GetArrayString(infectedPool, rndIndex, queuedTankSteamId, sizeof(queuedTankSteamId));
    for (new i=0; i<8; i++) {
        // If the selected player was substituted, choose their substitute for tank.
        if (strcmp(substitutes[i][0], queuedTankSteamId) == 0) {
            queuedTankSteamId = substitutes[i][1];
            break;
        }
    }
}

/**
 * Make sure we give the tank to our queued player.
 */
 
public Action:L4D_OnTryOfferingTankBot(tank_index, &bool:enterStatis)
{
    // Reset the tank's frustration if need be
    if (! IsFakeClient(tank_index))
    {
        for (new i = 1; i <= MaxClients; i++)
        {
            if (! IsClientInGame(i) || ! IsInfected(i))
                continue;

            PrintHintText(i, "Rage Meter Refilled");
            CPrintToChat(i, "{olive}[Tank Control] {default}(%N) {olive}Rage Meter Refilled", tank_index);
        }
        
        SetTankFrustration(tank_index, 100);
        L4D2Direct_SetTankPassedCount(L4D2Direct_GetTankPassedCount() + 1);
        
        return Plugin_Handled;
    }
    
    // If we don't have a queued tank, choose one
    if (! strcmp(queuedTankSteamId, ""))
        chooseTank();
    
    // Mark the player as having had tank
    if (strcmp(queuedTankSteamId, "") != 0)
    {
        setTankTickets(queuedTankSteamId, 20000);
        PushArrayString(h_whosHadTank, queuedTankSteamId);
        for (new i=0; i<8; i++) {
            // If the player is a substitute, we add the original player's name.
            // In other words, if your substitute gets the tank, so do you.
            if (strcmp(substitutes[i][1], queuedTankSteamId) == 0) {
                PushArrayString(h_whosHadTank, substitutes[i][0]);
                break;
            }
        }
    }
    
    return Plugin_Continue;
}

/**
 * Sets the amount of tickets for a particular player, essentially giving them tank.
 */
 
public setTankTickets(const String:steamId[], const tickets)
{
    new tankClientId = getInfectedPlayerBySteamId(steamId);
    
    for (new i = 1; i <= MaxClients; i++)
    {
        if (IsClientConnected(i) && IsClientInGame(i) && ! IsFakeClient(i) && IsInfected(i))
        {
            L4D2Direct_SetTankTickets(i, (i == tankClientId) ? tickets : 0);
        }
    }
}

/**
 * Output who will become tank
 */
 
public outputTankToAll()
{
    decl String:tankClientName[128];
    new tankClientId = getInfectedPlayerBySteamId(queuedTankSteamId);
    
    if (tankClientId != -1)
    {
        GetClientName(tankClientId, tankClientName, sizeof(tankClientName));
        if (GetConVarBool(hTankPrint))
        {
            CPrintToChatAll("{olive}%s {default}will become the tank!", tankClientName);
        }
        else
        {
            PrintToInfected("{olive}%s {default}will become the tank!", tankClientName);
        }
    }
}

stock PrintToInfected(const String:Message[], any:... )
{
    decl String:sPrint[256];
    VFormat(sPrint, sizeof(sPrint), Message, 2);

    for (new i = 1; i <= MaxClients; i++)
    {
        if (!IS_VALID_INFECTED(i))
        {
            continue;
        }

        CPrintToChat(i, "{default}%s", sPrint);
    }
}
/**
 * Returns an array of steam ids for a particular team.
 *
 * @param L4D2Team:team
 *     The team which to return steam ids for.
 *
 * @return
 *     An array of steam ids.
 */
 
public Handle:teamSteamIds(L4D2Team:team, bool:original)
{
    new Handle:steamIds = CreateArray(64);
    decl String:steamId[64];

    for (new i = 1; i <= MaxClients; i++)
    {
        // Basic check
        if (IsClientConnected(i) && IsClientInGame(i) && ! IsFakeClient(i))
        {
            // Checking if on our desired team
            if (L4D2Team:GetClientTeam(i) != team)
                continue;
        
            GetClientAuthString(i, steamId, sizeof(steamId));
            if (original) {
                for (new j=0; j<8; j++) {
                    // If this player was a substitute
                    if (strcmp(substitutes[j][1], steamId) == 0) {
                        steamId = substitutes[j][0];
                        break;
                    }
                }
            }
            PushArrayString(steamIds, steamId);
        }
    }
    
    return steamIds;
}

/**
 * Removes steam ids from the tank pool if they've already had tank.
 *
 * @param Handle:steamIdTankPool
 *     The pool of potential steam ids to become tank.
 * @param Handle:tanks
 *     The steam ids of players who've already had tank.
 *
 * @return
 *     The pool of steam ids who haven't had tank.
 */
 
public Handle:removeTanksFromPool(Handle:steamIdTankPool, Handle:tanks)
{
    decl index;
    decl String:steamId[64];
    
    for (new i = 0; i < GetArraySize(tanks); i++)
    {
        GetArrayString(tanks, i, steamId, sizeof(steamId));
        index = FindStringInArray(steamIdTankPool, steamId);
        
        if (index != -1)
        {
            RemoveFromArray(steamIdTankPool, index);
        }
    }
    
    return steamIdTankPool;
}

/**
 * Retrieves a player's client index by their steam id.
 *
 * @param const String:steamId[]
 *     The steam id to look for.
 *
 * @return
 *     The player's client index.
 */
 
public getInfectedPlayerBySteamId(const String:steamId[])
{
    decl String:tmpSteamId[64];
   
    for (new i = 1; i <= MaxClients; i++)
    {
        if (!IsClientConnected(i) || !IsInfected(i))
            continue;
        
        GetClientAuthString(i, tmpSteamId, sizeof(tmpSteamId));
        
        if (StrEqual(steamId, tmpSteamId))
            return i;
    }
    
    return -1;
}

/**
 * Sends a message to all clients console.
 *
 * @param format        Formatting rules.
 * @param ...            Variable number of format parameters.
 * @noreturn
 */
 
stock PrintToConsoleAll(const String:format[], any:...)
{
    decl String:text[192];
    for (new x = 1; x <= MaxClients; x++)
    {
        if (IsClientInGame(x))
        {
            SetGlobalTransTarget(x);
            VFormat(text, sizeof(text), format, 2);
            PrintToConsole(x, text);
        }
    }
}