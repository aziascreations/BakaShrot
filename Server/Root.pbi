;{- Code Header
; ==- Basic Info -================================
;     Name: Root.pbi
;  Version: 0.0.1
;   Author: Herwin Bozet (NibblePoker)
;
; ==- Compatibility -=============================
;  Tested compiler versions:
;    * PureBasic 5.73 LTS (Windows x64, Linux x64)
;    * PureBasic 6.40 C Backend (Windows x64)
;    * PureBasic 6.41 (Linux x64)
;    * PureBasic 6.41 C Backend (Linux x64)
;
; ==- Links -=====================================
;  GitHub: https://github.com/aziascreations/BakaShrot
;}

; ============================================================================
; BakaShrot Server Root
;
; What the main ("root") thread owns and does:
;   - The config.
;   - Its own database connection: setup, and maintenance while the workers
;     are stopped.
;   - The workers: the network server (its listener and one thread per
;     client, see Networking/Networking.pbi) and the peer links (one thread
;     per peer, see Networking/Peers.pbi).
;
; Stopping the workers is the root's signal to every other thread.
; BakaShrot_Root_StopWorkers() sets the StopRequested flag of the network
; server and the peer links, which every one of their threads checks within a
; few ms, then waits until each of those threads has exited. Each one closes
; its own database connection on its way out. So once it returns, the root's
; connection is the only one left, and the root can:
;   - BakaShrot_Root_Restart(): reload the config, reopen the database, start
;     again. Picks up config changes, like a client's permissions.
;   - BakaShrot_Root_Vacuum(): VACUUM the database, start again.
;   - Anything else that needs the database or the config to itself.
; Clients and peer links are dropped meanwhile. Peers relink on their own,
; clients have to reconnect.
;
; Only call these from the root thread.
; ============================================================================

XIncludeFile "Config/Config.pbi"
XIncludeFile "Storage/Storage.pbi"
XIncludeFile "Storage/Names.pbi"
XIncludeFile "Storage/Retention.pbi"
XIncludeFile "Networking/Networking.pbi"
XIncludeFile "Networking/Peers.pbi"


Structure BakaShrot_Root
	ConfigPath.s
	*Config.BakaShrot_CoreConfig

	; The root's own connection, only used for setup, and while the workers
	; are stopped.
	DbId.i

	; Both 0 while the workers are stopped.
	*Server.BakaShrot_NetServer
	*Peers.BakaShrot_PeerLinks
EndStructure


; Loads *Root\ConfigPath into *Root\Config, replacing the current one.
; Returns #False if it can't be loaded, the current one is then kept.
; Only while the workers are stopped, they use the config.
Procedure.i BakaShrot_Root_LoadConfig(*Root.BakaShrot_Root)
	Protected *Config.BakaShrot_CoreConfig
	Protected Known.BakaShrot_KnownNames, KnownError.String, DatabasePath.s, DbId.i

	; The names the database has first, so the ones the config lists without
	; an id keep theirs (Storage/Names.pbi). Nothing to read on a new one.
	DatabasePath = ReadConfigDatabasePath(*Root\ConfigPath)
	If DatabasePath <> "" And FileSize(DatabasePath) > 0
		DbId = OpenStorageDatabase(DatabasePath)
		If Not DbId Or Not SetupStorageDatabase(DbId) Or Not BakaShrot_Names_ReadKnown(DbId, @Known, @KnownError)
			PrintN("[Root] Failed to read the names of the database '" + DatabasePath + "': " + KnownError\s + DatabaseError())
			If DbId
				CloseDatabase(DbId)
			EndIf
			ProcedureReturn #False
		EndIf
		CloseDatabase(DbId)
	EndIf

	*Config = LoadConfig(*Root\ConfigPath, @Known)
	If Not *Config
		PrintN("[Root] Failed to load the config from '" + *Root\ConfigPath + "': " + BakaShrot_ConfigError)
		ProcedureReturn #False
	EndIf

	If *Root\Config
		FreeConfig(*Root\Config)
	EndIf
	*Root\Config = *Config

	PrintN("[Root] Loaded config '" + *Root\ConfigPath + "' (Node=" + *Config\NodeText + ", " + Str(MapSize(*Config\TopicNames())) + " named topics, " +
	       Str(MapSize(*Config\NodeNames())) + " named nodes, " + Str(MapSize(*Config\Peers())) + " peers, " + Str(MapSize(*Config\Clients())) + " clients)")
	ProcedureReturn #True
EndProcedure


; Opens the root's connection to the config's database, sets it up, and
; reconciles the config's topic and node names with it (Storage/Names.pbi).
; Returns #False if it can't be opened or set up, or if the names conflict.
Procedure.i BakaShrot_Root_OpenDatabase(*Root.BakaShrot_Root)
	Protected DatabasePath.s = *Root\Config\Server\DatabasePath
	Protected NamesError.String

	; Every connection opened from here on, the workers' included (they're
	; stopped meanwhile), takes it.
	BakaShrot_Storage_Synchronous = *Root\Config\Server\Synchronous

	*Root\DbId = OpenStorageDatabase(DatabasePath)
	If Not *Root\DbId
		PrintN("[Root] Failed to open the database '" + DatabasePath + "': " + DatabaseError())
		ProcedureReturn #False
	EndIf

	If Not SetupStorageDatabase(*Root\DbId)
		PrintN("[Root] Failed to set up the database '" + DatabasePath + "': " + DatabaseError())
		CloseDatabase(*Root\DbId)
		*Root\DbId = 0
		ProcedureReturn #False
	EndIf

	If Not BakaShrot_Names_Load(*Root\DbId, *Root\Config, @NamesError)
		PrintN("[Root] The config's names don't match the database '" + DatabasePath + "': " + NamesError\s)
		CloseDatabase(*Root\DbId)
		*Root\DbId = 0
		ProcedureReturn #False
	EndIf

	PrintN("[Root] Database '" + DatabasePath + "' is ready (synchronous " + BakaShrot_Storage_Synchronous + ")")
	ProcedureReturn #True
EndProcedure


Procedure BakaShrot_Root_CloseDatabase(*Root.BakaShrot_Root)
	If *Root\DbId
		CloseDatabase(*Root\DbId)
		*Root\DbId = 0
	EndIf
EndProcedure


; Starts the network server and the peer links.
; Returns #False if either can't start, nothing is left running then.
Procedure.i BakaShrot_Root_StartWorkers(*Root.BakaShrot_Root)
	Protected *Config.BakaShrot_CoreConfig = *Root\Config
	Protected WriterError.String

	; Every write goes through it, see Storage/Writer.pbi.
	If Not OpenStorageWriter(*Config\Server\DatabasePath, @WriterError)
		PrintN("[Root] Failed to open the storage writer: " + WriterError\s)
		ProcedureReturn #False
	EndIf

	; Deletes the messages past their topic's max age, see Storage/Retention.pbi.
	If Not StartStorageRetention(*Config)
		PrintN("[Root] Failed to start the retention thread")
		CloseStorageWriter()
		ProcedureReturn #False
	EndIf

	*Root\Server = BakaShrot_NetServer_Start(*Config\Server\Host, *Config\Server\Port, *Config)
	If Not *Root\Server
		PrintN("[Root] Failed to listen on '" + *Config\Server\Host + ":" + Str(*Config\Server\Port) + "'")
		StopStorageRetention()
		CloseStorageWriter()
		ProcedureReturn #False
	EndIf
	PrintN("[Root] Listening on '" + *Config\Server\Host + ":" + Str(*Config\Server\Port) + "'")

	*Root\Peers = BakaShrot_PeerLinks_Start(*Config)
	If Not *Root\Peers
		PrintN("[Root] Failed to start the peer links, are [BakaShrot] PrivateKey and every peer's PublicKey valid?")
		BakaShrot_NetServer_Stop(*Root\Server)
		*Root\Server = 0
		StopStorageRetention()
		CloseStorageWriter()
		ProcedureReturn #False
	EndIf

	ProcedureReturn #True
EndProcedure


; The signal: stops every worker thread and waits until they've all exited,
; which closes every database connection but the root's own.
; Peer links first, so they don't relink to a server that's going away.
Procedure BakaShrot_Root_StopWorkers(*Root.BakaShrot_Root)
	Protected StartTime.i = ElapsedMilliseconds()

	If *Root\Peers
		BakaShrot_PeerLinks_Stop(*Root\Peers)
		*Root\Peers = 0
	EndIf

	If *Root\Server
		BakaShrot_NetServer_Stop(*Root\Server)
		*Root\Server = 0
	EndIf

	StopStorageRetention()

	; Nothing writes anymore. Checkpoints the WAL into the database file.
	CloseStorageWriter()

	PrintN("[Root] Workers stopped in " + Str(ElapsedMilliseconds() - StartTime) + " ms")
EndProcedure


; Stops the workers, reloads the config (keeping the current one if the new
; one can't be loaded), reopens the database, and starts the workers again.
; Returns #False if the database can't be reopened or the workers can't
; start again, the server is then left stopped.
Procedure.i BakaShrot_Root_Restart(*Root.BakaShrot_Root)
	PrintN("[Root] Restarting")
	BakaShrot_Root_StopWorkers(*Root)

	If Not BakaShrot_Root_LoadConfig(*Root)
		PrintN("[Root] Keeping the current config")
	EndIf

	; The database path may have changed.
	BakaShrot_Root_CloseDatabase(*Root)
	If Not BakaShrot_Root_OpenDatabase(*Root)
		ProcedureReturn #False
	EndIf

	ProcedureReturn BakaShrot_Root_StartWorkers(*Root)
EndProcedure


; Stops the workers, VACUUMs the database, and starts the workers again.
; Returns #False if the workers can't start again, a failed VACUUM is only
; logged.
Procedure.i BakaShrot_Root_Vacuum(*Root.BakaShrot_Root)
	Protected StartTime.i

	PrintN("[Root] Vacuuming the database")
	BakaShrot_Root_StopWorkers(*Root)

	StartTime = ElapsedMilliseconds()
	If VacuumStorageDatabase(*Root\DbId)
		PrintN("[Root] Vacuumed in " + Str(ElapsedMilliseconds() - StartTime) + " ms")
	Else
		PrintN("[Root] Failed to vacuum: " + DatabaseError())
	EndIf

	ProcedureReturn BakaShrot_Root_StartWorkers(*Root)
EndProcedure
