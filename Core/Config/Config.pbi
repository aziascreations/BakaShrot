; ============================================================================
; BakaShrot Config
;
; Loads and saves the node's configuration from/to an ini file via
; PureBasic's native Preferences library.
;
; Section layout:
;   [BakaShrot]              -> BakaShrot_CoreConfig
;   [BakaShrot.Server]       -> BakaShrot_CoreConfig\Server
;   [BakaShrot.Client]       -> BakaShrot_CoreConfig\Client
;   [BakaShrot.Peer.<name>]  -> one BakaShrot_CoreConfig\Peers() entry per
;                                section; <name> is only a key for this file,
;                                it is never sent on the wire.
; ============================================================================


; Ini Section: [BakaShrot.Peer.<name>] (one section per known peer)
Structure BakaShrot_PeerConfig

	; Remote adress of the peer
	; Can be a domain name, IPV4, IPV6
	Host.s

	; Remote port of the peer
	; 0-65535
	Port.u

	; Remote node's GID
	; The connection will be aborted if it differs.
	GroupId.u

	; Remote node's node id
	; The connection will be aborted if it differs.
	NodeId.u

	; This peer's Ed25519 public key (Base64), used to verify the signature
	; on every packet it sends. See Networking/Cryptography.pbi.
	PublicKey.s

EndStructure


; Ini Section: [BakaShrot.Server]
Structure BakaShrot_ServerConfig

	; IPV4 that it will be bound to
	Host.s

	; Used port
	Port.u

	; List of groups from which the server will attempt to replicate from.
	; Format: 0;1;100-150;200;...
	List ReplicatingGroupIds.i()

EndStructure


; Ini Section: [BakaShrot.Client]
Structure BakaShrot_ClientConfig

	; No idea, feel free to suggest ideas

EndStructure


; Ini Section: [BakaShrot]
Structure BakaShrot_CoreConfig

	; This node's Ed25519 private key (Base64), used to sign every packet it
	; sends. Its matching public key must be handed to peers, who store it
	; as PublicKey in the relevant [BakaShrot.Peer.<name>] section of THEIR
	; own config. See Networking/Cryptography.pbi.
	PrivateKey.s

	; Replication Group ID to which the node belongs.
	; Will be used during the connection phase to identify itself.
	; Will be used to set the messages' GID
	; Will be used by itself and other nodes to know which messages to replicate and which to ignore.
	GroupId.u

	; Node ID that uniquely represents the node within a replication group.
	; Will be used during the connection phase to identify itself.
	; Will be used to set the messages' NID
	NodeId.u

	; [BakaShrot.Server]
	Server.BakaShrot_ServerConfig

	; [BakaShrot.Client]
	Client.BakaShrot_ClientConfig

	; One [BakaShrot.Peer.<name>] entry per map key.
	Map Peers.BakaShrot_PeerConfig()

EndStructure


Macro Ptr_BakaShrot_CoreConfig : i : EndMacro


; Parses a "0;1;100-150;200" style range list into a flat list of ids.
Procedure ParseGroupIdRanges(RangesString.s, List Ids.i())
	Protected i, Part.s, DashPos, FromId, ToId, Id

	ClearList(Ids())

	For i = 1 To CountString(RangesString, ";") + 1
		Part = Trim(StringField(RangesString, i, ";"))
		If Part = ""
			Continue
		EndIf

		DashPos = FindString(Part, "-")
		If DashPos
			FromId = Val(Left(Part, DashPos - 1))
			ToId   = Val(Mid(Part, DashPos + 1))
			For Id = FromId To ToId
				AddElement(Ids())
				Ids() = Id
			Next
		Else
			AddElement(Ids())
			Ids() = Val(Part)
		EndIf
	Next

EndProcedure


; Serializes a flat list of ids back into "id;id;id" form.
; (Ranges are not reconstructed on save; each id is written out individually.)
Procedure.s FormatGroupIdList(List Ids.i())
	Protected Result.s

	ForEach Ids()
		If Result <> ""
			Result + ";"
		EndIf
		Result + Str(Ids())
	Next

	ProcedureReturn Result
EndProcedure


Procedure.Ptr_BakaShrot_CoreConfig LoadConfig(IniFilePath.s)
	Protected *Config.BakaShrot_CoreConfig
	Protected GroupName.s, PeerName.s

	If Not OpenPreferences(IniFilePath)
		ProcedureReturn 0
	EndIf

	*Config = AllocateStructure(BakaShrot_CoreConfig)

	PreferenceGroup("BakaShrot")
	*Config\PrivateKey = ReadPreferenceString("PrivateKey", "")
	*Config\GroupId    = ReadPreferenceLong("GroupId", 0)
	*Config\NodeId     = ReadPreferenceLong("NodeId", 0)

	PreferenceGroup("BakaShrot.Server")
	*Config\Server\Host = ReadPreferenceString("Host", "")
	*Config\Server\Port = ReadPreferenceLong("Port", 0)
	ParseGroupIdRanges(ReadPreferenceString("ReplicatingGroupIds", ""), *Config\Server\ReplicatingGroupIds())

	; [BakaShrot.Client] has no fields yet.

	; Discover every [BakaShrot.Peer.<name>] section dynamically, so adding a
	; peer never needs a second "list of peer names" kept in sync by hand.
	ExaminePreferenceGroups()
	While NextPreferenceGroup()
		GroupName = PreferenceGroupName()

		If Left(GroupName, Len("BakaShrot.Peer.")) = "BakaShrot.Peer."
			PeerName = Mid(GroupName, Len("BakaShrot.Peer.") + 1)
			If PeerName <> ""
				AddMapElement(*Config\Peers(), PeerName)
				*Config\Peers()\Host      = ReadPreferenceString("Host", "")
				*Config\Peers()\Port      = ReadPreferenceLong("Port", 0)
				*Config\Peers()\GroupId   = ReadPreferenceLong("GroupId", 0)
				*Config\Peers()\NodeId    = ReadPreferenceLong("NodeId", 0)
				*Config\Peers()\PublicKey = ReadPreferenceString("PublicKey", "")
			EndIf
		EndIf
	Wend

	ClosePreferences()

	ProcedureReturn *Config
EndProcedure


Procedure.i SaveConfig(IniFilePath.s, *Config.BakaShrot_CoreConfig)

	If Not CreatePreferences(IniFilePath)
		ProcedureReturn #False
	EndIf

	PreferenceGroup("BakaShrot")
	WritePreferenceString("PrivateKey", *Config\PrivateKey)
	WritePreferenceLong("GroupId", *Config\GroupId)
	WritePreferenceLong("NodeId", *Config\NodeId)

	PreferenceGroup("BakaShrot.Server")
	WritePreferenceString("Host", *Config\Server\Host)
	WritePreferenceLong("Port", *Config\Server\Port)
	WritePreferenceString("ReplicatingGroupIds", FormatGroupIdList(*Config\Server\ReplicatingGroupIds()))

	PreferenceGroup("BakaShrot.Client")
	; No fields yet.

	ForEach *Config\Peers()
		PreferenceGroup("BakaShrot.Peer." + MapKey(*Config\Peers()))
		WritePreferenceString("Host", *Config\Peers()\Host)
		WritePreferenceLong("Port", *Config\Peers()\Port)
		WritePreferenceLong("GroupId", *Config\Peers()\GroupId)
		WritePreferenceLong("NodeId", *Config\Peers()\NodeId)
		WritePreferenceString("PublicKey", *Config\Peers()\PublicKey)
	Next

	ClosePreferences()

	ProcedureReturn #True
EndProcedure


Procedure FreeConfig(*Config.BakaShrot_CoreConfig)
	FreeStructure(*Config)
EndProcedure


; Usage example. Only compiled when this file is run directly (F5 in the
; IDE), not when it's included as a module by the rest of the project.
CompilerIf #PB_Compiler_IsMainFile

	Define *Config.BakaShrot_CoreConfig = LoadConfig("schema.ini")

	If *Config
		Debug "PrivateKey: " + *Config\PrivateKey
		Debug "GroupId: " + Str(*Config\GroupId)
		Debug "NodeId: " + Str(*Config\NodeId)

		Debug "Server: " + *Config\Server\Host + ":" + Str(*Config\Server\Port)
		ForEach *Config\Server\ReplicatingGroupIds()
			Debug "  Replicating group: " + Str(*Config\Server\ReplicatingGroupIds())
		Next

		ForEach *Config\Peers()
			Debug "Peer '" + MapKey(*Config\Peers()) + "': " + *Config\Peers()\Host + ":" + Str(*Config\Peers()\Port) + " PublicKey=" + *Config\Peers()\PublicKey
		Next

		SaveConfig("schema_out.ini", *Config)

		FreeConfig(*Config)
	Else
		Debug "Failed to load schema.ini"
	EndIf

CompilerEndIf
