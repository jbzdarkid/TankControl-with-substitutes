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
new Handle:h_tankQueue;
new String:queuedTankSteamId[64];
new Handle:hTankPrint;
new Handle:hTankDebug;
// A list of substitutions that have occured.
// [substitute slot][substitute/substitutee] = steamid
new String:substitutes[8][2][64];

public Plugin:myinfo =
{
    name = "L4D2 Tank Control",
    author = "arti, darkid",
    description = "Distributes the role of the tank evenly throughout the team",
    version = "0.2.2",
    url = "https://github.com/jbzdarkid/TankControl-with-substitutes/blob/master/l4d_tank_control.sp"
}

enum L4D2Team
{
    L4D2Team_None = 0,
    L4D2Team_Spectator,
    L4D2Team_Survivor,
    L4D2Team_Infected
}

enum ZClass
{
    ZClass_Smoker = 1,
    ZClass_Boomer = 2,
    ZClass_Hunter = 3,
    ZClass_Spitter = 4,
    ZClass_Jockey = 5,
    ZClass_Charger = 6,
    ZClass_Witch = 7,
    ZClass_Tank = 8
}

public APLRes:AskPluginLoad2(Handle:myself, bool:late, String:error[], err_max)
{
    CreateNative("TankControl_GetTankPool", Native_GetTankPool);
    CreateNative("TankControl_SetTank", Native_SetTank);
    
    return APLRes_Success;
}

/**
 * Set the player to become tank
 */
 
public Native_SetTank(Handle:plugin, numParams)
{
    new len;
    GetNativeStringLength(1, len);

    if (len <= 0)
    {
        return;
    }

    // Retrieve the arg
    new String:steamId[len + 1];
    GetNativeString(1, steamId, len + 1);
    
    // Queue that bad boy
    strcopy(queuedTankSteamId, sizeof(queuedTankSteamId), steamId);
}

/**
 * Native to retrieve the players currently available in the tank queued
 */

public Native_GetTankPool(Handle:plugin, numParams)
{
    // Create our pool of players to choose from
    h_tankQueue = teamSteamIds(L4D2Team_Infected);
    
    // If there is nobody on the infected team, return (otherwise we'd be stuck trying to select forever)
    if (GetArraySize(h_tankQueue) == 0)
        return _:h_tankQueue;
    
    // Remove players who've already had tank from the pool.
    h_tankQueue = removeTanksFromPool(h_tankQueue, h_whosHadTank, false);
    
    // If the infected pool is empty, remove infected players from pool
    if (GetArraySize(h_tankQueue) == 0) // (when nobody on infected ,error)
    {
        new Handle:infectedTeam = teamSteamIds(L4D2Team_Infected);
        if (GetArraySize(infectedTeam) > 1)
        {
            h_whosHadTank = removeTanksFromPool(h_whosHadTank, teamSteamIds(L4D2Team_Infected), false);
            h_tankQueue = removeTanksFromPool(h_tankQueue, h_whosHadTank, false);
        }
    }
    
    // Return the infected pool
    return _:h_tankQueue;
}

public OnPluginStart()
{
    // Load translations (for targeting player)
    LoadTranslations("common.phrases");
    
    // Event hooks
    HookEvent("player_left_start_area", EventHook:PlayerLeftStartArea_Event, EventHookMode_PostNoCopy);
    HookEvent("round_end", EventHook:RoundEnd_Event, EventHookMode_PostNoCopy);
    HookEvent("player_team", EventHook:PlayerTeam_Event, EventHookMode_PostNoCopy);
    HookEvent("tank_killed", EventHook:TankKilled_Event, EventHookMode_PostNoCopy);
    HookEvent("player_death", EventHook:PlayerDeath_Event, EventHookMode_Post);
    
    // Initialise the tank arrays/data values
    h_whosHadTank = CreateArray(64);
    
    // Register the boss commands
    RegConsoleCmd("sm_tank", Tank_Cmd, "Shows who is becoming the tank.");
    RegConsoleCmd("sm_boss", Tank_Cmd, "Shows who is becoming the tank.");
    RegConsoleCmd("sm_witch", Tank_Cmd, "Shows who is becoming the tank.");
    
    // Admin commands
    RegAdminCmd("sm_tankshuffle", TankShuffle_Cmd, ADMFLAG_SLAY, "Re-picks at random someone to become tank.");
    RegAdminCmd("sm_givetank", GiveTank_Cmd, ADMFLAG_SLAY, "Gives the tank to a selected player");
    
    // Cvars
    hTankPrint = CreateConVar("tankcontrol_print_all", "1", "Who gets to see who will become the tank? (0 = Infected, 1 = Everyone)", FCVAR_PLUGIN);
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
    
    // If it's a new game, reset the tank pool and substitute list
    if (teamAScore == 0 && teamBScore == 0)
    {
        h_whosHadTank = CreateArray(64);
        queuedTankSteamId = "";
        for (new i = 0; i < 8; i++) {
            substitutes[i][0] = "";
            substitutes[i][1] = "";
        }
    }
}

/**
 * When the round ends, reset the active tank.
 */
 
public RoundEnd_Event(Handle:event, const String:name[], bool:dontBroadcast)
{
    queuedTankSteamId = "";
}

/**
 * When a player leaves the start area, choose a tank and output to all.
 *
 * This method should only queue a new tank when:
 *  1. There is no tank queued, OR
 *  2. The queued tank doesn't pass validation (is not on infected team)
 */
 
public PlayerLeftStartArea_Event(Handle:event, const String:name[], bool:dontBroadcast)
{
    // Only choose a tank if nobody has been queued
    if (strcmp(queuedTankSteamId, "") == 0)
    {
        chooseTank();
    }
    
    // If the queued tank is not a valid infected player, choose another
    else
    {
        new tankClientId = getInfectedPlayerBySteamId(queuedTankSteamId);
        if (! IS_VALID_INFECTED(tankClientId))
        {
            chooseTank();
        }
    }
    
    outputTankToAll();
}

/**
 * When the queued tank switches teams, choose a new one.
 * When a player switches teams, track for substitutions.
 */
 
public PlayerTeam_Event(Handle:event, const String:name[], bool:dontBroadcast)
{
    new L4D2Team:newTeam = L4D2Team:GetEventInt(event, "team");
    new L4D2Team:oldTeam = L4D2Team:GetEventInt(event, "oldteam");
    new client = GetClientOfUserId(GetEventInt(event, "userid"));
    decl String:steamId[64];
    GetClientAuthString(client, steamId, sizeof(steamId));
    
    // When a player joins the game, figure out who they substituted for.
    if (newTeam == L4D2Team:L4D2Team_Infected || newTeam == L4D2Team:L4D2Team_Survivor) {
        new index = -1;
        new firstOpen = -1;
        new bool:wasRejoin = false;
        for (new i = 0; i < 8; i++) {
            // If the player who is joining has previously left
            if (strcmp(substitutes[i][1], steamId) == 0) {
                index = i;
                // If nobody has replaced them yet,
                if (strcmp(substitutes[i][0], "") != 0) {
                    substitutes[i][1] = "";
                    wasRejoin = true;
                    LogMessage("[TC-S] Player has rejoined.");
                    break;
                }
            }
            if (strcmp(substitutes[i][0], "") == 0 && strcmp(substitutes[i][1], "") != 0 && firstOpen == -1) {
                // A pair which looks like ["", steamid], which represents a substitute request.
                firstOpen = i;
            }
        }
        if (!wasRejoin) {
            if (firstOpen == -1) {
                LogMessage("[TC-S] ERROR: Joining player couldn't find a substitute spot.");
                return;
            }
            if (index == -1) { // A new player, assume they sub for the first person who needs it.
                substitutes[firstOpen][0] = steamId;
                LogMessage("[TC-S] Player substitute accepted.");
            } else { // A player rejoins, so simply pretend they never left and their substitute is replacing the recently departed player.
                substitutes[index][1] = substitutes[firstOpen][1];
                substitutes[firstOpen][1] = "";
                LogMessage("[TC-S] Player has rejoined, cleaning substitutions.");
            }
        }
    }
    
    // When a player leaves the game, prepare for a substitute player to arrive.
    if (oldTeam == L4D2Team:L4D2Team_Infected || oldTeam == L4D2Team:L4D2Team_Survivor) {
        new bool:newPlayer = true;
        new firstOpen = -1;
        for (new i = 0; i < 8; i++) {
            // If the player was already a substitute, simply mark the slot they substituted for as free again.
            if (strcmp(substitutes[i][0], steamId) == 0) {
                substitutes[i][0] = "";
                newPlayer = false;
                break;
            }
            if (strcmp(substitutes[i][0], "") == 0 && strcmp(substitutes[i][1], "") == 0 && firstOpen == -1) {
                // A pair which looks like ["", ""], which represents a free spot.
                firstOpen = i;
            }
        }
        // If the player was not already a substitute, create a new substitute slot for them.
        if (newPlayer) {
            if (firstOpen != -1) {
                substitutes[firstOpen][1] = steamId;
            } else { // If there are no open spots, then all 8 original players have already left. In that case, this player must have been a substitute.
                LogMessage("[TC-S] ERROR: Leaving player couldn't find substitute spot.");
            }
        }
    }
    
    
    if (client && oldTeam == L4D2Team:L4D2Team_Infected)
    {
        if (strcmp(queuedTankSteamId, steamId) == 0)
        {
            chooseTank();
            outputTankToAll();
        }
    }
}

/**
 * When the tank dies, requeue a player to become tank (for finales)
 */
 
public PlayerDeath_Event(Handle:event, const String:name[], bool:dontBroadcast)
{
    new zombieClass = 0;
    new victimId = GetEventInt(event, "userid");
    new victim = GetClientOfUserId(victimId);
    
    if (victimId && IsClientInGame(victim))
    {
        zombieClass = GetEntProp(victim, Prop_Send, "m_zombieClass");
        if (ZClass:zombieClass == ZClass_Tank)
        {
            if (GetConVarBool(hTankDebug))
            {
                LogMessage("[TC] Tank died(1), choosing a new tank");
            }
            chooseTank();
        }
    }
}

public TankKilled_Event(Handle:event, const String:name[], bool:dontBroadcast)
{
    if (GetConVarBool(hTankDebug))
    {
        LogMessage("[TC] Tank died(2), choosing a new tank");
    }
    chooseTank();
}

/**
 * When a player wants to find out whos becoming tank,
 * output to them.
 */
 
public Action:Tank_Cmd(client, args)
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
 * the pool.
 */
 
public Action:TankShuffle_Cmd(client, args)
{
    chooseTank();
    outputTankToAll();
    
    return Plugin_Handled;
}

/**
 * Give the tank to a specific player.
 */
 
public Action:GiveTank_Cmd(client, args)
{
    // Who are we targetting?
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
* Substitutes for players who have already had a tank are not considered.
* Once all original players (or their substitutes) have had a tank, substitutes will be considered.
*/

public chooseTank()
{
    // Create our pool of players to choose from
    new Handle:infectedPool = teamSteamIds(L4D2Team_Infected);

    // Remove players who've already had tank from the pool.
    infectedPool = removeTanksFromPool(infectedPool, h_whosHadTank, true);
    
    LogMessage("[TC-S] Choosing tank from original players...");
    
    // If there are no valid players, select from the actual players playing, i.e. include possible substitutes.
    if (GetArraySize(infectedPool) == 0) {
        LogMessage("[TC-S] No tanks in original pool.");
        LogMessage("[TC-S] Choosing tank from substitutes...");
        infectedPool = teamSteamIds(L4D2Team_Infected);
        infectedPool = removeTanksFromPool(infectedPool, h_whosHadTank, false);
    }

    for (new tank = 0; tank < GetArraySize(infectedPool); tank++) {
        new String:tankId[64];
        GetArrayString(infectedPool, tank, tankId, sizeof(tankId));
        
        new tankClientId = getInfectedPlayerBySteamId(queuedTankSteamId);
        
        new String:name[MAX_NAME_LENGTH];
        GetClientName(tankClientId, name, sizeof(name));
        
        LogMessage("[TC-S] Possible tank: %s", name);
    }

    // If there are still no valid players, put everyone back into the pool.
    if (GetArraySize(infectedPool) == 0) {
        LogMessage("[TC-S] No valid tanks, reseting pool.");
        infectedPool = teamSteamIds(L4D2Team_Infected);
        h_whosHadTank = removeTanksFromPool(h_whosHadTank, infectedPool, false);
        h_whosHadTank = removeTanksFromPool(h_whosHadTank, infectedPool, true);
        // Remove the substitutions, everyone in game has had a tank.
        for (new i = 0; i < 64; i++) {
            new String:steamId[64];
            GetArrayString(infectedPool, i, steamId, sizeof(steamId));
            for (new j = 0; j < 8; j++) {
                if (strcmp(substitutes[j][0], steamId) == 0) {
                    substitutes[j][0] = "";
                    substitutes[j][1] = "";
                }
            }
        }
        if (GetArraySize(infectedPool) == 0) {
            // No valid tanks
            queuedTankSteamId = "";
            return;
        }
    }

    // Select a random person to become tank
    new rndIndex = GetRandomInt(0, GetArraySize(infectedPool) - 1);
    GetArrayString(infectedPool, rndIndex, queuedTankSteamId, sizeof(queuedTankSteamId));
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

/**
 * Prints a message to the infected team
 *
 * @param String:Message[]
 *  The message to print
 */
 
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
 
public Handle:teamSteamIds(L4D2Team:team)
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
 * @param bool:substitute
 *
 *
 * @return
 *     The pool of steam ids who haven't had tank.
 */
 
public Handle:removeTanksFromPool(Handle:steamIdTankPool, Handle:tanks, bool:substitute)
{
    decl index;
    decl String:steamId[64];
    
    for (new i = 0; i < GetArraySize(tanks); i++)
    {
        GetArrayString(tanks, i, steamId, sizeof(steamId));
        if (substitute) {
            for (new j = 0; j < 8; j++) {
                // Replace the old player name with their substitute. If they've left, remove them anyways.
                if (strcmp(substitutes[j][1], steamId) == 0 && strcmp(substitutes[j][0], "") != 0) {
                    steamId = substitutes[j][0];
                    break;
                }
            }
        }
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
 
stock LogMessage(const String:format[], any:...)
{
    decl String:text[192];
    for (new x = 0; x <= MaxClients; x++)
    {
        if (IsClientInGame(x))
        {
            SetGlobalTransTarget(x);
            VFormat(text, sizeof(text), format, 2);
            PrintToConsole(x, text);
        }
    }
}