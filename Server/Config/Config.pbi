; ============================================================================
; BakaShrot Server Config
;
; Loads and saves the server node's configuration from/to an ini file via
; PureBasic's native Preferences library.
;
; Section layout:
;   [BakaShrot]                -> BakaShrot_CoreConfig
;   [BakaShrot.Server]         -> BakaShrot_CoreConfig\Server
;   [BakaShrot.Topics]         -> topic names, "name = id" lines
;   [BakaShrot.Nodes]          -> node names, "name = id" lines
;   [BakaShrot.Retention]      -> how long each topic's messages are kept
;                                  here, "topic = max age" lines, see
;                                  BakaShrot_RetentionRule
;   [BakaShrot.Peer.<name>]    -> one BakaShrot_CoreConfig\Peers() entry per
;                                  section.
;   [BakaShrot.Client.<name>]  -> one BakaShrot_CoreConfig\Clients() entry per
;                                  section.
;
; <name> of a peer or client section is only a key for this file, it is never
; sent on the wire. Topic and node names are: they're what other servers know
; them by, see Commons/Networking/Names.pbi.
;
; Everywhere else, a topic or node is a "ref": a name from those sections,
; or an id in digits. Topic and node lists ("0;logs;100-150;sensors.*") also
; take ranges of ids, patterns like file names ("sensors.*", "kitchen-??",
; see Commons/Networking/Names.pbi), and "*" for every one. In a peer's
; AcceptTopics / AcceptNodes, "*" and patterns also take names this server
; doesn't have: they're added with an id of their own, see
; Server/Storage/Names.pbi.
;
; LoadConfig() returns 0 on any mistake, with the reason in
; BakaShrot_ConfigError.
; ============================================================================

XIncludeFile "../../Commons/Networking/Names.pbi"
; #BakaShrot_MaxAttachmentSize.
XIncludeFile "../../Commons/Networking/Packets.pbi"


; Some topics or nodes, or all of them: what a topic list (or node list)
; in the config holds, see the top of this file.
Structure BakaShrot_NameSet
	; Every one, named or not, known or not ("*").
	All.i

	; Every one that has a name on this server: the default of AcceptNodes.
	Known.i

	; Str(Id) -> #True, from ids, ranges and names in the list.
	Map Ids.i()

	; Patterns ("sensors.*"), matched against names, known here or not:
	; a peer's topics and nodes it doesn't name are taken if they match.
	List Patterns.s()
EndStructure


; Ini Section: [BakaShrot.Peer.<name>] (one section per known peer)
; The server links to every peer on start, see Server/Networking/Peers.pbi.
; The peer must register this server in one of its [BakaShrot.Client.<name>].
; PublicKey is the peer's: a link to it only goes through if the peer
; proves it holds the matching private key (Commons/Networking/Connections.pbi).
; Topic and Node are only checked when the peer links to here.
Structure BakaShrot_PeerConfig

	; Remote address of the peer
	; Can be a domain name, IPV4, IPV6
	Host.s

	; Remote port of the peer
	; 0-65535
	Port.u

	; Topic, Node: the remote node's topic and node, refs, resolved to this
	; server's ids. The peer authenticates with them when it links to here.
	TopicId.u
	NodeId.u

	; This peer's Ed25519 public key (Base64): the Hello of a link to it is
	; sealed for it, and the peer must sign the handshake with the matching
	; private key. It also authenticates with it when it links to here.
	PublicKey.s

	; SendTopics: the topics this server sends to the peer (if the peer
	; takes them). AcceptTopics: the topics it takes from the peer.
	; Both default to [BakaShrot.Server] ReplicatingTopics.
	SendTopics.BakaShrot_NameSet
	AcceptTopics.BakaShrot_NameSet

	; SendNodes: the nodes whose messages this server sends to the peer.
	; Default: every one (*). AcceptNodes: the nodes whose messages it takes
	; from the peer. Default: every one named here, no other.
	SendNodes.BakaShrot_NameSet
	AcceptNodes.BakaShrot_NameSet

	; As written in the ini, for SaveConfig(). Chr(1) when missing.
	SendTopicsText.s
	AcceptTopicsText.s
	SendNodesText.s
	AcceptNodesText.s
	TopicText.s
	NodeText.s

EndStructure


; One "Topic:Node" entry of BakaShrot_ClientConfig\Identities().
Structure BakaShrot_ClientIdentity
	TopicId.u
	NodeId.u
EndStructure


; What a client is allowed to do once authenticated.
; Ini keys of [BakaShrot.Client.<name>], 1 to allow, 0 to deny.
Structure BakaShrot_ClientPermissions

	; AllowRead: GetLatestMessage. Defaults to 1.
	Read.i

	; AllowWrite: PushMessage. Defaults to 1.
	Write.i

	; AllowQuery: raw read-only SQL queries. Defaults to 0, they can read
	; every topic's data.
	Query.i

EndStructure

#BakaShrot_Config_DefaultAllowRead  = 1
#BakaShrot_Config_DefaultAllowWrite = 1
#BakaShrot_Config_DefaultAllowQuery = 0


; Ini Section: [BakaShrot.Client.<name>] (one section per registered client)
Structure BakaShrot_ClientConfig

	; Ed25519 public keys (Base64) the client is allowed to authenticate with.
	; Format: Key;Key;...
	List PublicKeys.s()

	; Topic and node pairs the client is allowed to authenticate as, once it
	; has authenticated with one of its PublicKeys.
	; Format: Topic:Node;Topic:Node;... each a name or an id.
	List Identities.BakaShrot_ClientIdentity()

	; AllowRead, AllowWrite, AllowQuery
	Permissions.BakaShrot_ClientPermissions

	; PushTopics: the topics it may push to, under its own node.
	; ReadTopics: the topics it may read the latest messages of.
	; Both default to the topics of its Identities.
	PushTopics.BakaShrot_NameSet
	ReadTopics.BakaShrot_NameSet

	; As written in the ini, for SaveConfig(). Chr(1) when missing.
	IdentitiesText.s
	PushTopicsText.s
	ReadTopicsText.s

EndStructure


; One line of [BakaShrot.Retention]: messages of the topics it matches may
; be deleted from this server once they were pushed MaxAgeMs ago (see
; Server/Storage/Retention.pbi). Only this server's: each server keeps its
; own, a peer keeps what it was sent as long as its own rules say.
;   logs = 30d          one topic, by name (known here or not) or id
;   sensors.* = 12h     a pattern, matching names (Commons/Networking/Names.pbi)
;   * = 365d            every other topic
; Ages: numbers with a unit, s m h d w, added up ("1d12h"); "forever" (or
; 0) keeps them. A topic takes its id's line, else its name's, else the
; first pattern matching it, in the file's order, else "*"'s. Without any
; line, messages are kept forever.
Enumeration BakaShrot_RetentionKinds
	#BakaShrot_Retention_Id      = 1
	#BakaShrot_Retention_Name    = 2
	#BakaShrot_Retention_Pattern = 3
	#BakaShrot_Retention_Default = 4
EndEnumeration

Structure BakaShrot_RetentionRule
	Kind.i
	; As written: the topic's name or id, the pattern, or "*".
	Ref.s
	; For #BakaShrot_Retention_Id.
	TopicId.i
	; 0: kept forever.
	MaxAgeMs.q
	; The age as written, for SaveConfig() and the logs.
	AgeText.s
EndStructure


; Ini Section: [BakaShrot.Server]
Structure BakaShrot_ServerConfig

	; IPV4 that it will be bound to
	Host.s

	; Used port
	Port.u

	; ReplicatingTopics: the topics replicated with every peer that doesn't
	; say otherwise (SendTopics, AcceptTopics).
	; Format: 0;logs;100-150;200;... or * for every topic.
	ReplicatingTopics.BakaShrot_NameSet
	ReplicatingTopicsText.s

	; Amount of threads used for networking-related tasks
	NetThreadPoolSize.i

	; SQLite database file holding the messages.
	DatabasePath.s

	; Seconds to wait before connecting to a peer again, after failing to
	; connect or losing the connection.
	PeerRetryDelay.i

	; Seconds between two check-ins with a linked peer, where it's sent the
	; messages it's missing.
	PeerSyncInterval.i

	; Most messages sent to a peer per packet when it's missing some, 1-10000.
	; A batch is also cut short to fit in one packet (64 KB).
	PeerBatchSize.i

	; Seconds between two passes deleting the messages past their topic's
	; max age ([BakaShrot.Retention]). Default 60.
	RetentionInterval.i

	; Biggest attachment this server takes, in bytes: pushed with a message,
	; or replicated (a bigger one's message is kept, not its attachment).
	; Written with a unit: 500M, 1G (K M G T, 1024-based). Default 1G.
	MaxAttachmentSize.q
	MaxAttachmentSizeText.s

	; Seconds an upload may take, before it's pushed with its message: past
	; that it's deleted. Default 3600.
	UploadTimeout.i

EndStructure


; Ini Section: [BakaShrot]
Structure BakaShrot_CoreConfig

	; This node's Ed25519 private key (Base64), used to sign every packet it
	; sends. Its matching public key must be handed to peers, who store it
	; as PublicKey in the relevant [BakaShrot.Peer.<name>] section of THEIR
	; own config. See Commons/Cryptography/Libsodium.pbi.
	PrivateKey.s

	; Topic, Node: the topic and node this server authenticates as when it
	; links to its peers, refs. Peers must know them by the same names.
	TopicId.u
	NodeId.u
	TopicText.s
	NodeText.s

	; [BakaShrot.Server]
	Server.BakaShrot_ServerConfig

	; [BakaShrot.Topics] and [BakaShrot.Nodes]:
	; LCase(name) -> id, and Str(id) -> name as written.
	Map TopicIds.i()
	Map TopicNames.s()
	Map NodeIds.i()
	Map NodeNames.s()

	; Str(id) -> #True for every id the config mentions, named or not, so
	; the database knows them all (Server/Storage/Names.pbi).
	Map UsedTopicIds.i()
	Map UsedNodeIds.i()

	; [BakaShrot.Retention], in the file's order.
	List Retention.BakaShrot_RetentionRule()

	; One [BakaShrot.Peer.<name>] entry per map key.
	Map Peers.BakaShrot_PeerConfig()

	; One [BakaShrot.Client.<name>] entry per map key.
	Map Clients.BakaShrot_ClientConfig()

EndStructure


Macro Ptr_BakaShrot_CoreConfig : i : EndMacro


#BakaShrot_Config_DefaultNetThreadPoolSize = 4
#BakaShrot_Config_DefaultDatabasePath      = "./test.sqlite"
#BakaShrot_Config_DefaultPeerRetryDelay    = 10
#BakaShrot_Config_DefaultPeerSyncInterval  = 5
#BakaShrot_Config_DefaultPeerBatchSize     = 100
#BakaShrot_Config_DefaultRetentionInterval = 60
#BakaShrot_Config_DefaultMaxAttachmentSize = "1G"
#BakaShrot_Config_DefaultUploadTimeout     = 3600

; What ReadPreferenceString() returns for a missing key, to tell it from an
; empty one: an empty PushTopics allows nothing, a missing one the default.
#BakaShrot_Config_Missing = Chr(1)


; Why the last LoadConfig() failed.
Global BakaShrot_ConfigError.s = ""


; Reads Key, or OldKey if Key is missing: Topic, Node and ReplicatingTopics
; were TopicId, NodeId and ReplicatingTopicIds before they took names, and
; configs written then still work.
Procedure.s ReadConfigKey(Key.s, OldKey.s, DefaultValue.s)
	Protected Value.s = ReadPreferenceString(Key, #BakaShrot_Config_Missing)
	If Value = #BakaShrot_Config_Missing
		Value = ReadPreferenceString(OldKey, DefaultValue)
	EndIf
	ProcedureReturn Value
EndProcedure


; #True if *Set holds the topic or node Id named Name: Name is its name
; ("" if it has none), Id is -1 for a name this server doesn't know.
; Not thread-safe, it moves the set's current map and list elements: give
; each thread its own copy (CopyStructure()).
Procedure.i NameSetHas(*Set.BakaShrot_NameSet, Id.i, Name.s)
	If *Set\All
		ProcedureReturn #True
	EndIf
	If Id >= 0 And FindMapElement(*Set\Ids(), Str(Id))
		ProcedureReturn #True
	EndIf
	If Name <> ""
		If *Set\Known And Id >= 0
			ProcedureReturn #True
		EndIf
		ForEach *Set\Patterns()
			If BakaShrot_GlobMatch(*Set\Patterns(), Name)
				ProcedureReturn #True
			EndIf
		Next
	EndIf
	ProcedureReturn #False
EndProcedure

; #True if *Set has anything that can take names this server doesn't know
; ("*" or a pattern).
Procedure.i NameSetTakesUnknown(*Set.BakaShrot_NameSet)
	ProcedureReturn Bool(*Set\All Or ListSize(*Set\Patterns()) > 0)
EndProcedure


; The id a topic ref stands for in *Config, -1 if it's neither an id nor one
; of its [BakaShrot.Topics].
; An empty ref is 0, like an empty key always was.
Procedure.i ResolveConfigTopic(*Config.BakaShrot_CoreConfig, Ref.s)
	Protected Id.i

	If Ref = ""
		Ref = "0"
	EndIf
	Id = BakaShrot_RefToId(Ref)

	If Id >= 0
		ProcedureReturn Id
	EndIf
	If BakaShrot_IsValidName(Ref) And FindMapElement(*Config\TopicIds(), LCase(Ref))
		ProcedureReturn *Config\TopicIds()
	EndIf
	ProcedureReturn -1
EndProcedure

; Same for a node ref and [BakaShrot.Nodes].
Procedure.i ResolveConfigNode(*Config.BakaShrot_CoreConfig, Ref.s)
	Protected Id.i

	If Ref = ""
		Ref = "0"
	EndIf
	Id = BakaShrot_RefToId(Ref)

	If Id >= 0
		ProcedureReturn Id
	EndIf
	If BakaShrot_IsValidName(Ref) And FindMapElement(*Config\NodeIds(), LCase(Ref))
		ProcedureReturn *Config\NodeIds()
	EndIf
	ProcedureReturn -1
EndProcedure


; An age as [BakaShrot.Retention] writes it ("30d", "1d12h", "forever") in
; milliseconds, 0 for forever, -1 if it isn't one.
Procedure.q ParseRetentionAge(Text.s)
	Protected i.i, c.s, Digits.s, Total.q, Unit.q, Seen.i

	Text = LCase(Trim(Text))
	If Text = "forever" Or Text = "0"
		ProcedureReturn 0
	EndIf
	If Text = ""
		ProcedureReturn -1
	EndIf

	For i = 1 To Len(Text)
		c = Mid(Text, i, 1)
		If c >= "0" And c <= "9"
			Digits + c
			If Len(Digits) > 9
				ProcedureReturn -1
			EndIf
			Continue
		EndIf
		Select c
			Case "s" : Unit = 1000
			Case "m" : Unit = 60 * 1000
			Case "h" : Unit = 3600 * 1000
			Case "d" : Unit = 86400 * 1000
			Case "w" : Unit = 7 * 86400 * 1000
			Default  : ProcedureReturn -1
		EndSelect
		; A unit needs its number: "d" or "1dd" isn't an age.
		If Digits = ""
			ProcedureReturn -1
		EndIf
		Total + Val(Digits) * Unit
		Digits = ""
		Seen = #True
	Next

	; A number without a unit: seconds or days? Refused rather than guessed.
	If Digits <> "" Or Not Seen
		ProcedureReturn -1
	EndIf
	ProcedureReturn Total
EndProcedure


; A size as MaxAttachmentSize writes it ("500M", "1G", "1048576") in bytes,
; -1 if it isn't one. Units are 1024-based: K M G T.
Procedure.q ParseConfigSize(Text.s)
	Protected Unit.q = 1, Digits.s, Last.s, i.i

	Text = UCase(Trim(Text))
	If Text = ""
		ProcedureReturn -1
	EndIf
	Last = Right(Text, 1)
	Select Last
		Case "K" : Unit = 1024
		Case "M" : Unit = 1024 * 1024
		Case "G" : Unit = 1024 * 1024 * 1024
		Case "T" : Unit = 1024 * 1024 * 1024 * 1024
	EndSelect
	Digits = Text
	If Unit > 1
		Digits = Left(Text, Len(Text) - 1)
	EndIf
	If Digits = "" Or Len(Digits) > 13
		ProcedureReturn -1
	EndIf
	For i = 1 To Len(Digits)
		If Mid(Digits, i, 1) < "0" Or Mid(Digits, i, 1) > "9"
			ProcedureReturn -1
		EndIf
	Next
	ProcedureReturn Val(Digits) * Unit
EndProcedure


; Reads [BakaShrot.Retention] into *Config\Retention().
; Returns #False on an invalid line, with the reason in BakaShrot_ConfigError.
Procedure.i ParseRetentionSection(*Config.BakaShrot_CoreConfig)
	Protected Ref.s, Value.s, MaxAge.q, Id.i

	If Not PreferenceGroup("BakaShrot.Retention")
		ProcedureReturn #True
	EndIf

	If ExaminePreferenceKeys()
		While NextPreferenceKey()
			Ref   = Trim(PreferenceKeyName())
			Value = Trim(PreferenceKeyValue())
			MaxAge = ParseRetentionAge(Value)
			If MaxAge < 0
				BakaShrot_ConfigError = "[BakaShrot.Retention] " + Ref + " = '" + Value + "' isn't an age: numbers with a unit (s m h d w), like 30d or 1d12h, or 'forever'"
				ProcedureReturn #False
			EndIf

			AddElement(*Config\Retention())
			*Config\Retention()\Ref      = Ref
			*Config\Retention()\MaxAgeMs = MaxAge
			*Config\Retention()\AgeText  = Value
			*Config\Retention()\TopicId  = -1
			Id = BakaShrot_RefToId(Ref)
			If Ref = "*"
				*Config\Retention()\Kind = #BakaShrot_Retention_Default
			ElseIf Id >= 0
				*Config\Retention()\Kind    = #BakaShrot_Retention_Id
				*Config\Retention()\TopicId = Id
			ElseIf BakaShrot_IsValidName(Ref)
				; A name this config doesn't have may still come from a peer.
				*Config\Retention()\Kind = #BakaShrot_Retention_Name
			ElseIf BakaShrot_IsValidPattern(Ref)
				*Config\Retention()\Kind = #BakaShrot_Retention_Pattern
			Else
				BakaShrot_ConfigError = "[BakaShrot.Retention] '" + Ref + "' isn't a topic name, id, pattern or *"
				ProcedureReturn #False
			EndIf
		Wend
	EndIf

	; Two lines for the same topic: the second would silently lose.
	Protected NewMap Seen.i()
	ForEach *Config\Retention()
		Ref = LCase(*Config\Retention()\Ref)
		If FindMapElement(Seen(), Ref)
			BakaShrot_ConfigError = "[BakaShrot.Retention] '" + *Config\Retention()\Ref + "' is given twice"
			ProcedureReturn #False
		EndIf
		Seen(Ref) = #True
	Next

	ProcedureReturn #True
EndProcedure


; How long a topic's messages are kept by *Config's [BakaShrot.Retention],
; in ms, 0 for forever. Name is "" for an unnamed topic.
Procedure.q RetentionMaxAgeMs(List Rules.BakaShrot_RetentionRule(), TopicId.i, Name.s)
	Protected *Default.BakaShrot_RetentionRule, *Named.BakaShrot_RetentionRule, *Matched.BakaShrot_RetentionRule

	ForEach Rules()
		Select Rules()\Kind
			Case #BakaShrot_Retention_Id
				If Rules()\TopicId = TopicId
					ProcedureReturn Rules()\MaxAgeMs
				EndIf
			Case #BakaShrot_Retention_Name
				If Not *Named And Name <> "" And LCase(Rules()\Ref) = LCase(Name)
					*Named = @Rules()
				EndIf
			Case #BakaShrot_Retention_Pattern
				If Not *Matched And Name <> "" And BakaShrot_GlobMatch(Rules()\Ref, Name)
					*Matched = @Rules()
				EndIf
			Case #BakaShrot_Retention_Default
				*Default = @Rules()
		EndSelect
	Next

	If *Named
		ProcedureReturn *Named\MaxAgeMs
	ElseIf *Matched
		ProcedureReturn *Matched\MaxAgeMs
	ElseIf *Default
		ProcedureReturn *Default\MaxAgeMs
	EndIf
	ProcedureReturn 0
EndProcedure


; Reads a "name = id" section into Ids() (LCase(name) -> id) and Names()
; (Str(id) -> name). Kind is "topic" or "node", for the errors.
; Returns #False on an invalid name or id, or one given twice.
Procedure.i ParseNameSection(Section.s, Kind.s, Map Ids.i(), Map Names.s())
	Protected Name.s, Value.s, Id.i

	If Not PreferenceGroup(Section)
		ProcedureReturn #True
	EndIf

	If ExaminePreferenceKeys()
		While NextPreferenceKey()
			Name  = Trim(PreferenceKeyName())
			Value = Trim(PreferenceKeyValue())
			If Not BakaShrot_IsValidName(Name)
				BakaShrot_ConfigError = "[" + Section + "] '" + Name + "' isn't a valid " + Kind + " name: 1-" + Str(#BakaShrot_MaxNameLength) + " of A-Z a-z 0-9 _ . -, not only digits"
				ProcedureReturn #False
			EndIf
			Id = BakaShrot_RefToId(Value)
			If Id < 0
				BakaShrot_ConfigError = "[" + Section + "] " + Name + " = '" + Value + "' isn't an id, 0-" + Str(#BakaShrot_MaxId)
				ProcedureReturn #False
			EndIf
			If FindMapElement(Ids(), LCase(Name))
				BakaShrot_ConfigError = "[" + Section + "] " + Kind + " '" + Name + "' is given twice"
				ProcedureReturn #False
			EndIf
			If FindMapElement(Names(), Str(Id))
				BakaShrot_ConfigError = "[" + Section + "] " + Kind + " id " + Str(Id) + " is given to both '" + Names() + "' and '" + Name + "'"
				ProcedureReturn #False
			EndIf
			Ids(LCase(Name)) = Id
			Names(Str(Id))   = Name
		Wend
	EndIf

	ProcedureReturn #True
EndProcedure


; Parses a topic list (IsNodes #False) or node list into *Set: refs,
; patterns and ranges of ids separated by ";", "*" for every one, see the
; top of this file. Where is for the errors.
; Returns #False on an unknown name, an invalid pattern or range.
Procedure.i ParseNameSet(*Config.BakaShrot_CoreConfig, Text.s, *Set.BakaShrot_NameSet, IsNodes.i, Where.s)
	Protected i.i, Part.s, DashPos.i, FromId.i, ToId.i, Id.i, Kind.s, Section.s

	Kind = "topic" : Section = "[BakaShrot.Topics]"
	If IsNodes
		Kind = "node" : Section = "[BakaShrot.Nodes]"
	EndIf

	ClearMap(*Set\Ids())
	ClearList(*Set\Patterns())
	*Set\All   = #False
	*Set\Known = #False

	For i = 1 To CountString(Text, ";") + 1
		Part = Trim(StringField(Text, i, ";"))
		If Part = ""
			Continue
		EndIf

		If Part = "*"
			*Set\All = #True
			Continue
		EndIf

		If FindString(Part, "*") Or FindString(Part, "?")
			If Not BakaShrot_IsValidPattern(Part)
				BakaShrot_ConfigError = Where + ": '" + Part + "' isn't a valid pattern, * and ? among A-Z a-z 0-9 _ . -"
				ProcedureReturn #False
			EndIf
			AddElement(*Set\Patterns())
			*Set\Patterns() = Part
			Continue
		EndIf

		; Names can have dashes too, only digits on both sides make a range.
		DashPos = FindString(Part, "-")
		If DashPos And BakaShrot_IsDigits(Trim(Left(Part, DashPos - 1))) And BakaShrot_IsDigits(Trim(Mid(Part, DashPos + 1)))
			FromId = BakaShrot_RefToId(Trim(Left(Part, DashPos - 1)))
			ToId   = BakaShrot_RefToId(Trim(Mid(Part, DashPos + 1)))
			If FromId < 0 Or ToId < 0 Or FromId > ToId
				BakaShrot_ConfigError = Where + ": '" + Part + "' isn't a valid range of ids"
				ProcedureReturn #False
			EndIf
			For Id = FromId To ToId
				*Set\Ids(Str(Id)) = #True
				If IsNodes
					*Config\UsedNodeIds(Str(Id)) = #True
				Else
					*Config\UsedTopicIds(Str(Id)) = #True
				EndIf
			Next
		Else
			If IsNodes
				Id = ResolveConfigNode(*Config, Part)
			Else
				Id = ResolveConfigTopic(*Config, Part)
			EndIf
			If Id < 0
				BakaShrot_ConfigError = Where + ": unknown " + Kind + " '" + Part + "', not an id, a pattern, nor in " + Section
				ProcedureReturn #False
			EndIf
			*Set\Ids(Str(Id)) = #True
			If IsNodes
				*Config\UsedNodeIds(Str(Id)) = #True
			Else
				*Config\UsedTopicIds(Str(Id)) = #True
			EndIf
		EndIf
	Next

	ProcedureReturn #True
EndProcedure

; A topic list, see ParseNameSet().
Procedure.i ParseTopicSet(*Config.BakaShrot_CoreConfig, Text.s, *Set.BakaShrot_NameSet, Where.s)
	ProcedureReturn ParseNameSet(*Config, Text, *Set, #False, Where)
EndProcedure


; Parses a "Key;Key;..." list into a list of Base64 public keys.
Procedure ParsePublicKeyList(KeysString.s, List Keys.s())
	Protected i, Part.s

	ClearList(Keys())

	For i = 1 To CountString(KeysString, ";") + 1
		Part = Trim(StringField(KeysString, i, ";"))
		If Part = ""
			Continue
		EndIf

		AddElement(Keys())
		Keys() = Part
	Next

EndProcedure


; Serializes a list of Base64 public keys back into "Key;Key;..." form.
Procedure.s FormatPublicKeyList(List Keys.s())
	Protected Result.s

	ForEach Keys()
		If Result <> ""
			Result + ";"
		EndIf
		Result + Keys()
	Next

	ProcedureReturn Result
EndProcedure


; Parses a "Topic:Node;Topic:Node;..." list into a list of identities.
; Returns #False if an entry isn't exactly "Topic:Node" with known refs,
; since silently turning a typo into a 0:0 identity would grant an identity
; nobody asked for.
Procedure.i ParseIdentityList(*Config.BakaShrot_CoreConfig, IdentitiesString.s, List Identities.BakaShrot_ClientIdentity(), Where.s)
	Protected i, Part.s, TopicPart.s, NodePart.s, TopicId.i, NodeId.i

	ClearList(Identities())

	For i = 1 To CountString(IdentitiesString, ";") + 1
		Part = Trim(StringField(IdentitiesString, i, ";"))
		If Part = ""
			Continue
		EndIf

		If CountString(Part, ":") <> 1
			BakaShrot_ConfigError = Where + ": '" + Part + "' isn't Topic:Node"
			ProcedureReturn #False
		EndIf

		TopicPart = Trim(StringField(Part, 1, ":"))
		NodePart  = Trim(StringField(Part, 2, ":"))
		If TopicPart = "" Or NodePart = ""
			BakaShrot_ConfigError = Where + ": '" + Part + "' isn't Topic:Node"
			ProcedureReturn #False
		EndIf
		TopicId = ResolveConfigTopic(*Config, TopicPart)
		NodeId  = ResolveConfigNode(*Config, NodePart)
		If TopicId < 0
			BakaShrot_ConfigError = Where + ": unknown topic '" + TopicPart + "', not an id nor in [BakaShrot.Topics]"
			ProcedureReturn #False
		EndIf
		If NodeId < 0
			BakaShrot_ConfigError = Where + ": unknown node '" + NodePart + "', not an id nor in [BakaShrot.Nodes]"
			ProcedureReturn #False
		EndIf

		AddElement(Identities())
		Identities()\TopicId = TopicId
		Identities()\NodeId  = NodeId
		*Config\UsedTopicIds(Str(TopicId)) = #True
		*Config\UsedNodeIds(Str(NodeId))   = #True
	Next

	ProcedureReturn #True
EndProcedure


; Returns the name of the [BakaShrot.Client.<name>] section allowing both
; PublicKey and the TopicId:NodeId identity, or "" if none does.
; Not thread-safe, it moves *Config\Clients()' current element.
Procedure.s FindClientName(*Config.BakaShrot_CoreConfig, PublicKey.s, TopicId.i, NodeId.i)
	Protected KeyAllowed.i, IdentityAllowed.i

	ForEach *Config\Clients()
		KeyAllowed = #False
		ForEach *Config\Clients()\PublicKeys()
			If *Config\Clients()\PublicKeys() = PublicKey
				KeyAllowed = #True
				Break
			EndIf
		Next

		IdentityAllowed = #False
		ForEach *Config\Clients()\Identities()
			If *Config\Clients()\Identities()\TopicId = TopicId And *Config\Clients()\Identities()\NodeId = NodeId
				IdentityAllowed = #True
				Break
			EndIf
		Next

		If KeyAllowed And IdentityAllowed
			ProcedureReturn MapKey(*Config\Clients())
		EndIf
	Next

	ProcedureReturn ""
EndProcedure


; Returns the name of the [BakaShrot.Peer.<name>] section with exactly this
; public key and TopicId:NodeId identity, or "" if none has.
; Not thread-safe, it moves *Config\Peers()' current element.
Procedure.s FindPeerName(*Config.BakaShrot_CoreConfig, PublicKey.s, TopicId.i, NodeId.i)
	ForEach *Config\Peers()
		If *Config\Peers()\PublicKey = PublicKey And *Config\Peers()\TopicId = TopicId And *Config\Peers()\NodeId = NodeId
			ProcedureReturn MapKey(*Config\Peers())
		EndIf
	Next

	ProcedureReturn ""
EndProcedure


Procedure FreeConfig(*Config.BakaShrot_CoreConfig)
	FreeStructure(*Config)
EndProcedure


; Loads IniFilePath. Returns 0 on failure, with the reason in BakaShrot_ConfigError.
Procedure.Ptr_BakaShrot_CoreConfig LoadConfig(IniFilePath.s)
	Protected *Config.BakaShrot_CoreConfig
	Protected GroupName.s, PeerName.s, ClientName.s, Text.s, Id.i
	Protected NewList PeerNames.s(), NewList ClientNames.s()
	Protected Failed.i = #False

	BakaShrot_ConfigError = ""

	If Not OpenPreferences(IniFilePath)
		BakaShrot_ConfigError = "can't open '" + IniFilePath + "'"
		ProcedureReturn 0
	EndIf

	*Config = AllocateStructure(BakaShrot_CoreConfig)
	If Not *Config
		ClosePreferences()
		BakaShrot_ConfigError = "out of memory"
		ProcedureReturn 0
	EndIf

	; Names first, everything else can refer to them.
	If Not ParseNameSection("BakaShrot.Topics", "topic", *Config\TopicIds(), *Config\TopicNames()) Or
	   Not ParseNameSection("BakaShrot.Nodes", "node", *Config\NodeIds(), *Config\NodeNames())
		Goto LoadFailed
	EndIf
	ForEach *Config\TopicNames()
		*Config\UsedTopicIds(MapKey(*Config\TopicNames())) = #True
	Next
	ForEach *Config\NodeNames()
		*Config\UsedNodeIds(MapKey(*Config\NodeNames())) = #True
	Next

	PreferenceGroup("BakaShrot")
	*Config\PrivateKey = ReadPreferenceString("PrivateKey", "")
	*Config\TopicText  = Trim(ReadConfigKey("Topic", "TopicId", "0"))
	*Config\NodeText   = Trim(ReadConfigKey("Node", "NodeId", "0"))
	Id = ResolveConfigTopic(*Config, *Config\TopicText)
	If Id < 0
		BakaShrot_ConfigError = "[BakaShrot] Topic: unknown topic '" + *Config\TopicText + "'"
		Goto LoadFailed
	EndIf
	*Config\TopicId = Id
	Id = ResolveConfigNode(*Config, *Config\NodeText)
	If Id < 0
		BakaShrot_ConfigError = "[BakaShrot] Node: unknown node '" + *Config\NodeText + "'"
		Goto LoadFailed
	EndIf
	*Config\NodeId = Id
	*Config\UsedTopicIds(Str(*Config\TopicId)) = #True
	*Config\UsedNodeIds(Str(*Config\NodeId))   = #True

	PreferenceGroup("BakaShrot.Server")
	*Config\Server\Host              = ReadPreferenceString("Host", "")
	*Config\Server\Port              = ReadPreferenceLong("Port", 0)
	*Config\Server\NetThreadPoolSize = ReadPreferenceLong("NetThreadPoolSize", #BakaShrot_Config_DefaultNetThreadPoolSize)
	*Config\Server\DatabasePath      = ReadPreferenceString("DatabasePath", #BakaShrot_Config_DefaultDatabasePath)
	*Config\Server\PeerRetryDelay    = ReadPreferenceLong("PeerRetryDelay", #BakaShrot_Config_DefaultPeerRetryDelay)
	*Config\Server\PeerSyncInterval  = ReadPreferenceLong("PeerSyncInterval", #BakaShrot_Config_DefaultPeerSyncInterval)
	*Config\Server\PeerBatchSize     = ReadPreferenceLong("PeerBatchSize", #BakaShrot_Config_DefaultPeerBatchSize)
	*Config\Server\RetentionInterval = ReadPreferenceLong("RetentionInterval", #BakaShrot_Config_DefaultRetentionInterval)
	If *Config\Server\RetentionInterval < 1
		BakaShrot_ConfigError = "[BakaShrot.Server] RetentionInterval must be 1 second or more"
		Goto LoadFailed
	EndIf
	*Config\Server\MaxAttachmentSizeText = Trim(ReadPreferenceString("MaxAttachmentSize", #BakaShrot_Config_DefaultMaxAttachmentSize))
	*Config\Server\MaxAttachmentSize     = ParseConfigSize(*Config\Server\MaxAttachmentSizeText)
	If *Config\Server\MaxAttachmentSize < 0 Or *Config\Server\MaxAttachmentSize > #BakaShrot_MaxAttachmentSize
		BakaShrot_ConfigError = "[BakaShrot.Server] MaxAttachmentSize = '" + *Config\Server\MaxAttachmentSizeText + "' isn't a size up to 1T: bytes, or a number with K, M, G or T, like 500M (0: no attachments)"
		Goto LoadFailed
	EndIf
	*Config\Server\UploadTimeout = ReadPreferenceLong("UploadTimeout", #BakaShrot_Config_DefaultUploadTimeout)
	If *Config\Server\UploadTimeout < 10
		BakaShrot_ConfigError = "[BakaShrot.Server] UploadTimeout must be 10 seconds or more"
		Goto LoadFailed
	EndIf
	*Config\Server\ReplicatingTopicsText = ReadConfigKey("ReplicatingTopics", "ReplicatingTopicIds", "")
	If Not ParseTopicSet(*Config, *Config\Server\ReplicatingTopicsText, @*Config\Server\ReplicatingTopics, "[BakaShrot.Server] ReplicatingTopics")
		Goto LoadFailed
	EndIf

	If Not ParseRetentionSection(*Config)
		Goto LoadFailed
	EndIf

	; Every [BakaShrot.Peer.<name>] and [BakaShrot.Client.<name>], found
	; dynamically so adding one never needs a second "list of names" kept in
	; sync by hand. Read once the walk is done: PreferenceGroup() inside it
	; would lose the walk's place.
	If ExaminePreferenceGroups()
		While NextPreferenceGroup()
			GroupName = PreferenceGroupName()
			If Left(GroupName, Len("BakaShrot.Peer.")) = "BakaShrot.Peer." And Len(GroupName) > Len("BakaShrot.Peer.")
				AddElement(PeerNames())
				PeerNames() = Mid(GroupName, Len("BakaShrot.Peer.") + 1)
			EndIf
			If Left(GroupName, Len("BakaShrot.Client.")) = "BakaShrot.Client." And Len(GroupName) > Len("BakaShrot.Client.")
				AddElement(ClientNames())
				ClientNames() = Mid(GroupName, Len("BakaShrot.Client.") + 1)
			EndIf
		Wend
	EndIf

	ForEach PeerNames()
		PeerName = PeerNames()
		PreferenceGroup("BakaShrot.Peer." + PeerName)
		AddMapElement(*Config\Peers(), PeerName)
		With *Config\Peers()
			\Host      = ReadPreferenceString("Host", "")
			\Port      = ReadPreferenceLong("Port", 0)
			\PublicKey = ReadPreferenceString("PublicKey", "")
			\TopicText = Trim(ReadConfigKey("Topic", "TopicId", "0"))
			\NodeText  = Trim(ReadConfigKey("Node", "NodeId", "0"))
			Id = ResolveConfigTopic(*Config, \TopicText)
			If Id < 0
				BakaShrot_ConfigError = "[BakaShrot.Peer." + PeerName + "] Topic: unknown topic '" + \TopicText + "'"
				Failed = #True : Break
			EndIf
			\TopicId = Id
			Id = ResolveConfigNode(*Config, \NodeText)
			If Id < 0
				BakaShrot_ConfigError = "[BakaShrot.Peer." + PeerName + "] Node: unknown node '" + \NodeText + "'"
				Failed = #True : Break
			EndIf
			\NodeId = Id
			*Config\UsedTopicIds(Str(\TopicId)) = #True
			*Config\UsedNodeIds(Str(\NodeId))   = #True

			\SendTopicsText = ReadPreferenceString("SendTopics", #BakaShrot_Config_Missing)
			If \SendTopicsText = #BakaShrot_Config_Missing
				CopyStructure(@*Config\Server\ReplicatingTopics, @\SendTopics, BakaShrot_NameSet)
			ElseIf Not ParseTopicSet(*Config, \SendTopicsText, @\SendTopics, "[BakaShrot.Peer." + PeerName + "] SendTopics")
				Failed = #True : Break
			EndIf

			\AcceptTopicsText = ReadPreferenceString("AcceptTopics", #BakaShrot_Config_Missing)
			If \AcceptTopicsText = #BakaShrot_Config_Missing
				CopyStructure(@*Config\Server\ReplicatingTopics, @\AcceptTopics, BakaShrot_NameSet)
			ElseIf Not ParseTopicSet(*Config, \AcceptTopicsText, @\AcceptTopics, "[BakaShrot.Peer." + PeerName + "] AcceptTopics")
				Failed = #True : Break
			EndIf

			\SendNodesText = ReadPreferenceString("SendNodes", #BakaShrot_Config_Missing)
			If \SendNodesText = #BakaShrot_Config_Missing
				\SendNodes\All = #True
			ElseIf Not ParseNameSet(*Config, \SendNodesText, @\SendNodes, #True, "[BakaShrot.Peer." + PeerName + "] SendNodes")
				Failed = #True : Break
			EndIf

			\AcceptNodesText = ReadPreferenceString("AcceptNodes", #BakaShrot_Config_Missing)
			If \AcceptNodesText = #BakaShrot_Config_Missing
				\AcceptNodes\Known = #True
			ElseIf Not ParseNameSet(*Config, \AcceptNodesText, @\AcceptNodes, #True, "[BakaShrot.Peer." + PeerName + "] AcceptNodes")
				Failed = #True : Break
			EndIf
		EndWith
	Next
	If Failed
		Goto LoadFailed
	EndIf

	ForEach ClientNames()
		ClientName = ClientNames()
		PreferenceGroup("BakaShrot.Client." + ClientName)
		AddMapElement(*Config\Clients(), ClientName)
		With *Config\Clients()
			ParsePublicKeyList(ReadPreferenceString("PublicKeys", ""), \PublicKeys())
			\IdentitiesText = ReadPreferenceString("Identities", "")
			If Not ParseIdentityList(*Config, \IdentitiesText, \Identities(), "[BakaShrot.Client." + ClientName + "] Identities")
				Failed = #True : Break
			EndIf
			\Permissions\Read  = Bool(ReadPreferenceLong("AllowRead", #BakaShrot_Config_DefaultAllowRead) <> 0)
			\Permissions\Write = Bool(ReadPreferenceLong("AllowWrite", #BakaShrot_Config_DefaultAllowWrite) <> 0)
			\Permissions\Query = Bool(ReadPreferenceLong("AllowQuery", #BakaShrot_Config_DefaultAllowQuery) <> 0)

			; By default, only the topics it authenticates in, like before.
			\PushTopicsText = ReadPreferenceString("PushTopics", #BakaShrot_Config_Missing)
			\ReadTopicsText = ReadPreferenceString("ReadTopics", #BakaShrot_Config_Missing)
			If \PushTopicsText = #BakaShrot_Config_Missing
				ForEach \Identities()
					\PushTopics\Ids(Str(\Identities()\TopicId)) = #True
				Next
			ElseIf Not ParseTopicSet(*Config, \PushTopicsText, @\PushTopics, "[BakaShrot.Client." + ClientName + "] PushTopics")
				Failed = #True : Break
			EndIf
			If \ReadTopicsText = #BakaShrot_Config_Missing
				ForEach \Identities()
					\ReadTopics\Ids(Str(\Identities()\TopicId)) = #True
				Next
			ElseIf Not ParseTopicSet(*Config, \ReadTopicsText, @\ReadTopics, "[BakaShrot.Client." + ClientName + "] ReadTopics")
				Failed = #True : Break
			EndIf
		EndWith
	Next
	If Failed
		Goto LoadFailed
	EndIf

	ClosePreferences()
	ProcedureReturn *Config

	LoadFailed:
	ClosePreferences()
	FreeConfig(*Config)
	ProcedureReturn 0
EndProcedure


; Writes a key, unless its text is #BakaShrot_Config_Missing.
Procedure WriteConfigText(Key.s, Text.s)
	If Text <> #BakaShrot_Config_Missing
		WritePreferenceString(Key, Text)
	EndIf
EndProcedure


; Saves *Config back, lists and refs as they were written in the ini.
Procedure.i SaveConfig(IniFilePath.s, *Config.BakaShrot_CoreConfig)

	If Not CreatePreferences(IniFilePath)
		ProcedureReturn #False
	EndIf

	PreferenceGroup("BakaShrot")
	WritePreferenceString("PrivateKey", *Config\PrivateKey)
	WritePreferenceString("Topic", *Config\TopicText)
	WritePreferenceString("Node", *Config\NodeText)

	PreferenceGroup("BakaShrot.Server")
	WritePreferenceString("Host", *Config\Server\Host)
	WritePreferenceLong("Port", *Config\Server\Port)
	WritePreferenceString("ReplicatingTopics", *Config\Server\ReplicatingTopicsText)
	WritePreferenceLong("NetThreadPoolSize", *Config\Server\NetThreadPoolSize)
	WritePreferenceString("DatabasePath", *Config\Server\DatabasePath)
	WritePreferenceLong("PeerRetryDelay", *Config\Server\PeerRetryDelay)
	WritePreferenceLong("PeerSyncInterval", *Config\Server\PeerSyncInterval)
	WritePreferenceLong("PeerBatchSize", *Config\Server\PeerBatchSize)
	WritePreferenceLong("RetentionInterval", *Config\Server\RetentionInterval)
	WritePreferenceString("MaxAttachmentSize", *Config\Server\MaxAttachmentSizeText)
	WritePreferenceLong("UploadTimeout", *Config\Server\UploadTimeout)

	PreferenceGroup("BakaShrot.Topics")
	ForEach *Config\TopicNames()
		WritePreferenceString(*Config\TopicNames(), MapKey(*Config\TopicNames()))
	Next

	PreferenceGroup("BakaShrot.Nodes")
	ForEach *Config\NodeNames()
		WritePreferenceString(*Config\NodeNames(), MapKey(*Config\NodeNames()))
	Next

	If ListSize(*Config\Retention())
		PreferenceGroup("BakaShrot.Retention")
		ForEach *Config\Retention()
			WritePreferenceString(*Config\Retention()\Ref, *Config\Retention()\AgeText)
		Next
	EndIf

	ForEach *Config\Peers()
		PreferenceGroup("BakaShrot.Peer." + MapKey(*Config\Peers()))
		WritePreferenceString("Host", *Config\Peers()\Host)
		WritePreferenceLong("Port", *Config\Peers()\Port)
		WritePreferenceString("Topic", *Config\Peers()\TopicText)
		WritePreferenceString("Node", *Config\Peers()\NodeText)
		WritePreferenceString("PublicKey", *Config\Peers()\PublicKey)
		WriteConfigText("SendTopics", *Config\Peers()\SendTopicsText)
		WriteConfigText("AcceptTopics", *Config\Peers()\AcceptTopicsText)
		WriteConfigText("SendNodes", *Config\Peers()\SendNodesText)
		WriteConfigText("AcceptNodes", *Config\Peers()\AcceptNodesText)
	Next

	ForEach *Config\Clients()
		PreferenceGroup("BakaShrot.Client." + MapKey(*Config\Clients()))
		WritePreferenceString("PublicKeys", FormatPublicKeyList(*Config\Clients()\PublicKeys()))
		WritePreferenceString("Identities", *Config\Clients()\IdentitiesText)
		WritePreferenceLong("AllowRead", *Config\Clients()\Permissions\Read)
		WritePreferenceLong("AllowWrite", *Config\Clients()\Permissions\Write)
		WritePreferenceLong("AllowQuery", *Config\Clients()\Permissions\Query)
		WriteConfigText("PushTopics", *Config\Clients()\PushTopicsText)
		WriteConfigText("ReadTopics", *Config\Clients()\ReadTopicsText)
	Next

	ClosePreferences()

	ProcedureReturn #True
EndProcedure


; Usage example. Only compiled when this file is run directly (F5 in the
; IDE), not when it's included as a module by the rest of the project.
CompilerIf #PB_Compiler_IsMainFile

	Define *Config.BakaShrot_CoreConfig = LoadConfig("schema.ini")

	If *Config
		Debug "PrivateKey: " + *Config\PrivateKey
		Debug "TopicId: " + Str(*Config\TopicId)
		Debug "NodeId: " + Str(*Config\NodeId)

		Debug "Server: " + *Config\Server\Host + ":" + Str(*Config\Server\Port)
		Debug "  NetThreadPoolSize: " + Str(*Config\Server\NetThreadPoolSize)
		Debug "  Replicating: " + *Config\Server\ReplicatingTopicsText

		ForEach *Config\TopicNames()
			Debug "Topic " + *Config\TopicNames() + " = " + MapKey(*Config\TopicNames())
		Next
		ForEach *Config\NodeNames()
			Debug "Node " + *Config\NodeNames() + " = " + MapKey(*Config\NodeNames())
		Next

		ForEach *Config\Peers()
			Debug "Peer '" + MapKey(*Config\Peers()) + "': " + *Config\Peers()\Host + ":" + Str(*Config\Peers()\Port) + " PublicKey=" + *Config\Peers()\PublicKey
		Next

		ForEach *Config\Clients()
			Debug "Client '" + MapKey(*Config\Clients()) + "':"
			ForEach *Config\Clients()\PublicKeys()
				Debug "  PublicKey: " + *Config\Clients()\PublicKeys()
			Next
			ForEach *Config\Clients()\Identities()
				Debug "  Identity: " + Str(*Config\Clients()\Identities()\TopicId) + ":" + Str(*Config\Clients()\Identities()\NodeId)
			Next
		Next

		SaveConfig("schema_out.ini", *Config)

		FreeConfig(*Config)
	Else
		Debug "Failed to load schema.ini: " + BakaShrot_ConfigError
	EndIf

CompilerEndIf
