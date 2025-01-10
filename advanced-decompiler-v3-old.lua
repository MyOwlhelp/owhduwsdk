
--!optimize 2

--TODO: add --optimize hotcomment support if possible even?
--TODO: stop listing nested upvalues and use them directly
--TODO: use letter "u" instead of "v" for upvalues

;;CONSTANTS HERE;;

-- TEMPORARY
local POINT_TYPE_END = 0
local POINT_TYPE_ELSE = 1
local POINT_TYPE_ELSEIF = 2

-- maybe move this somewhere? its just faster bit32 funcs
local lshift, rshift
function lshift(x, disp)
	if disp < 0 then return rshift(x,-disp) end
	return (x * 2^disp) % 2^32
end
function rshift(x, disp)
	if disp < 0 then return lshift(x,-disp) end
	return (x % 2^32) // (2^disp)
end

local function LoadFromUrl(x)
	local BASE_USER = "w-a-e"
	local BASE_BRANCH = "main"
	local BASE_URL = "https://raw.githubusercontent.com/%s/Advanced-Decompiler-V3/%s/%s.lua"

	local loadSuccess, loadResult = pcall(function()
		local formattedUrl = string.format(BASE_URL, BASE_USER, BASE_BRANCH, x)
		return game:HttpGet(formattedUrl, true)
	end)

	if not loadSuccess then
		warn(`({math.random()}) MОDULE FАILЕD ТO LOАD FRОM URL: {loadResult}.`)
		return
	end

	local success, result = pcall(loadstring, loadResult)
	if not success then
		warn(`({math.random()}) MОDULE FАILЕD ТO LOАDSТRING: {result}.`)
		return
	end

	if type(result) ~= "function" then
		warn(`MОDULE IS {tostring(result)} (function expected)`)
		return
	end

	return result()
end
local Implementations = LoadFromUrl("Implementations")
local Reader = LoadFromUrl("Reader")
local Strings = LoadFromUrl("Strings")
local Luau = LoadFromUrl("Luau")

local LuauOpCode = Luau.OpCode
local LuauBytecodeTag = Luau.BytecodeTag
local LuauBytecodeType = Luau.BytecodeType
local LuauCaptureType = Luau.CaptureType
local LuauBuiltinFunction = Luau.BuiltinFunction
local LuauProtoFlag = Luau.ProtoFlag

local toboolean = Implementations.toboolean
local toEscapedString = Implementations.toEscapedString
local formatIndexString = Implementations.formatIndexString
local isGlobal = Implementations.isGlobal

Reader:Set(READER_FLOAT_PRECISION)

local function Decompile(bytecode)
	local bytecodeVersion, typeEncodingVersion
	--
	local reader = Reader.new(bytecode)
	--
	-- collects all information from the bytecode and organizes it
	local function disassemble()
		if bytecodeVersion >= 4 then
			-- type encoding did not exist before this version
			typeEncodingVersion = reader:nextByte()
		end

		local stringTable = {}
		local function readStringTable()
			local sizeStringTable = reader:nextVarInt()
			for i = 1, sizeStringTable do
				stringTable[i] = reader:nextString()
			end
		end
		readStringTable()

		local protoTable = {}
		local function readProtoTable()
			local sizeProtoTable = reader:nextVarInt()
			for i = 1, sizeProtoTable do
				local protoId = i - 1 -- account for main proto

				local proto = {
					id = protoId,

					insnTable = {},
					constsTable = {},
					innerProtoTable = {},

					smallLineInfo = {},
					largeLineInfo = {},
					-- stores information about the first instruction to help detect inlining
					firstInstruction = nil
				}
				protoTable[protoId] = proto

				-- read header
				proto.maxStackSize = reader:nextByte()
				proto.numParams = reader:nextByte()
				proto.numUpvalues = reader:nextByte()
				proto.isVarArg = toboolean(reader:nextByte())

				-- prepare a table for upvalue references for further use if there are any
				if proto.numUpvalues > 0 then
					proto.nestedUpvalues = table.create(proto.numUpvalues)
				end

				-- read flags and typeinfo if bytecode version includes that information
				if bytecodeVersion >= 4 then
					proto.flags = reader:nextByte()
					proto.typeinfo = reader:nextBytes(reader:nextVarInt()) -- array of uint8
				end

				proto.sizeInsns = reader:nextVarInt() -- total number of instructions
				for i = 1, proto.sizeInsns do
					local encodedInsn = reader:nextUInt32()
					proto.insnTable[i] = encodedInsn
				end

				-- this might be confusing but just read into it
				proto.sizeConsts = reader:nextVarInt() -- total number of constants
				for i = 1, proto.sizeConsts do
					local constType = reader:nextByte()
					local constValue

					if constType == LuauBytecodeTag.LBC_CONSTANT_BOOLEAN then
						-- 1 = true, 0 = false
						constValue = toboolean(reader:nextByte())
					elseif constType == LuauBytecodeTag.LBC_CONSTANT_NUMBER then
						constValue = reader:nextDouble()
					elseif constType == LuauBytecodeTag.LBC_CONSTANT_STRING then
						local stringId = reader:nextVarInt()
						constValue = stringTable[stringId]
					elseif constType == LuauBytecodeTag.LBC_CONSTANT_IMPORT then
						local id = reader:nextUInt32()

						local indexCount = rshift(id, 30)

						local cacheIndex1 = bit32.band(rshift(id, 20), 0x3FF)
						local cacheIndex2 = bit32.band(rshift(id, 10), 0x3FF)
						local cacheIndex3 = bit32.band(rshift(id, 0), 0x3FF)

						local importTag = "("

						if indexCount == 1 then
							local k1 = proto.constsTable[cacheIndex1 + 1]
							importTag ..= tostring(k1.value)
						elseif indexCount == 2 then
							local k1 = proto.constsTable[cacheIndex1 + 1]
							local k2 = proto.constsTable[cacheIndex2 + 1]
							importTag ..= tostring(k1.value) .. ", "
							importTag ..= tostring(k2.value)
						elseif indexCount == 3 then
							local k1 = proto.constsTable[cacheIndex1 + 1]
							local k2 = proto.constsTable[cacheIndex2 + 1]
							local k3 = proto.constsTable[cacheIndex3 + 1]
							importTag ..= tostring(k1.value) .. ", "
							importTag ..= tostring(k2.value) .. ", "
							importTag ..= tostring(k3.value)
						end

						importTag ..= ")"

						constValue = "import - " .. importTag
					elseif constType == LuauBytecodeTag.LBC_CONSTANT_TABLE then
						local sizeTable = reader:nextVarInt()
						local tableKeys = {}

						for _ = 1, sizeTable do
							local keyStringId = reader:nextVarInt() + 1
							table.insert(tableKeys, keyStringId)
						end

						constValue = { ["size"] = sizeTable, ["keys"] = tableKeys }
					elseif constType == LuauBytecodeTag.LBC_CONSTANT_CLOSURE then
						local closureId = reader:nextVarInt() + 1
						constValue = closureId
					elseif constType == LuauBytecodeTag.LBC_CONSTANT_VECTOR then
						local x, y, z, w = reader:nextFloat(), reader:nextFloat(), reader:nextFloat(), reader:nextFloat()
						if w ~= 0 then
							constValue = `Vector3.new({x}, {y}, {z}, {w})`
						else
							constValue = `Vector3.new({x}, {y}, {z})`
						end
					elseif constType ~= LuauBytecodeTag.LBC_CONSTANT_NIL then
						-- handle unknown constant type later
					end

					proto.constsTable[i] = { ["type"] = constType, ["value"] = constValue }
				end

				proto.sizeInnerProtos = reader:nextVarInt() -- total number of protos inside this proto
				for i = 1, proto.sizeInnerProtos do
					local protoId = reader:nextVarInt()
					proto.innerProtoTable[i] = protoTable[protoId]
				end

				-- lineDefined is the line function starts on
				proto.lineDefined = reader:nextVarInt()
				-- protoSourceId is the string id of the function's name if it is not unnamed
				local protoSourceId = reader:nextVarInt()
				proto.source = stringTable[protoSourceId]

				-- smallLineInfo contains lines for each instruction
				-- largeLineInfo contains lines for each 256 line chunk proto uses
				local hasLineInfo = toboolean(reader:nextByte())
				if hasLineInfo then
					-- this code is confusing
					local logspan = reader:nextByte() -- uint8

					local intervals = rshift(proto.sizeInsns - 1, logspan) + 1

					local lastOffset = 0
					local lastLine = 0

					local added = {}
					local smallLineInfo = {}
					local largeLineInfo = {}

					for i, insn in proto.insnTable do
						local val = reader:nextByte()
						local prevInsn = proto.insnTable[i - 1]
						if prevInsn then
							local insnOP = Luau:INSN_OP(prevInsn)
							local opInfo = LuauOpCode[insnOP]
							if opInfo and opInfo.aux then
								-- ignore aux lines
								val = 0
							end
						end
						local currOP = Luau:INSN_OP(insn)
						local currOPInfo = LuauOpCode[currOP]
						if currOPInfo then
							if string.find(currOPInfo.type, "sD") then
								-- works in most cases but still gotta replace this
								local sD = Luau:INSN_sD(insn)
								if sD < -1 and val ~= 0 then
									val -= (0xFF + 1)
								end
							elseif currOPInfo.name == "CALL" and val > 0 then
								-- TODO: replace later. i dont trust this. check if there is a pointer to an instruction less than the current one
								val -= (0xFF + 1)
							end
						end
						smallLineInfo[i] = val
					end

					for i = 1, intervals do
						local val = reader:nextUInt32()
						largeLineInfo[i - 1] = val
					end

					for i, offset in smallLineInfo do
						-- HELP HELP HELP HELP HELP HELP HELP HELP HELP HELP HELP HELP HELP HELP HELP HELP HELP HELP HELP HELP
						local largeLineIndex = rshift(i - 0.1, logspan)
						local largeLine
						if not added[largeLineIndex] then
							added[largeLineIndex] = true
							largeLine = largeLineInfo[largeLineIndex]
							lastLine += largeLine
							if largeLineIndex ~= 0 then
								offset = 0
								lastOffset = offset
							end
						end
						local lineInsn = proto.insnTable[i]
						local lineOP = lineInsn and Luau:INSN_OP(lineInsn)
						local lineOPInfo = LuauOpCode[lineOP]
						lastOffset += offset
						if i == 1 then
							proto.firstInstruction = {lineOPInfo and lineOPInfo.name, largeLine}
						end
						proto.smallLineInfo[i] = lastOffset
						proto.largeLineInfo[i] = bit32.band(lastLine, 0xFFFF)
					end
				end

				-- debug info is local and function parameter names, all that
				local hasDebugInfo = toboolean(reader:nextByte())
				if hasDebugInfo then
					-- script does not use Roblox bytecode
					return ":("
				end
			end
		end
		readProtoTable()

		local mainProtoId = reader:nextVarInt()
		return protoTable[mainProtoId], protoTable, stringTable
	end
	local function roughDecompilation()
		local output = ""

		local mainProto, protoTable, stringTable = disassemble()

		local inlineRemarks = {}
		local function handleInlinedCalls()
			-- its either my lineinfo implementation is faulty or roblox's inlining
			-- is so bad they mess up line numbers. i hate it so much
			-- also this is not trustworthy, if anyone comes up with a better method
			-- try it out
			for i, proto in protoTable do
				local smallLineInfo = proto.smallLineInfo
				local largeLineInfo = proto.largeLineInfo

				local lineDefined = proto.lineDefined

				local insnTable = proto.insnTable

				local validProtos = {}
				for i, otherProto in protoTable do
					local protoName = otherProto.source
					if protoName and otherProto.lineDefined < lineDefined then
						validProtos[i] = otherProto
					end
				end

				local lineOffset = 0
				local queuedInsns = {}

				for i, insn in insnTable do
					local instructionLine = smallLineInfo[i]
					local largeInstructionLine = largeLineInfo[i]

					if queuedInsns[i] then
						queuedInsns[i] = nil
					else
						local prevInstructionLine = smallLineInfo[i - 1]
						local largePrevInstructionLine = largeLineInfo[i - 1]

						if not prevInstructionLine or ((instructionLine + largeInstructionLine) - (prevInstructionLine + largePrevInstructionLine)) >= 30 then
							local actualInstructionLine = largeInstructionLine + (instructionLine - (0xFF + 1))

							local insnOP = Luau:INSN_OP(insn)
							local opInfo = LuauOpCode[insnOP]

							if opInfo then
								for _, otherProto in validProtos do
									local protoName = otherProto.source
									local firstInstructionInfo = otherProto.firstInstruction
									if opInfo.name == firstInstructionInfo[1] and actualInstructionLine == firstInstructionInfo[2] then
										-- this instruction was used in another function previously defined
										if ENABLED_REMARKS.INLINE_REMARK then
											inlineRemarks[i..insn] = protoName
										end
										lineOffset += (0xFF + 1)
										for x = i, i + otherProto.sizeInsns - 1 do
											queuedInsns[x] = true
										end
										break
									end
								end
							end
						end
					end

					smallLineInfo[i] = instructionLine - lineOffset
				end
			end
		end
		handleInlinedCalls()

		local globalData = {}

		local totalParams = 0
		local totalVars = 0

		local function baseProto(proto, depth, isMainProto)
			local localData = {}
			local refData = {}
			--local upvalRefData = {}

			local ifLoopPoints = {}
			local promotedJumps = {}
			local function createLoopPoint(jumpId, pointId)
				--TODO: fix this system. it only works for relatively simplistic if thens and idk why I called it loop point

				if promotedJumps[jumpId] then
					-- promoted to elseif, end is not needed
					return
				end

				local pointData = ifLoopPoints[pointId] or table.create(1)

				local pointInsn = proto.insnTable[pointId]
				local pointOP = pointInsn and Luau:INSN_OP(pointInsn)
				local pointInfo = LuauOpCode[pointOP]
				if pointInfo and pointInfo.name == "JUMP" then
					local promote = false

					local jumpEndPoint = pointId + Luau:INSN_sD(pointInsn)
					-- analyze closest jump in range
					for i = pointId + 1, jumpEndPoint do
						local insn = proto.insnTable[i]
						local op = Luau:INSN_OP(insn)
						local opInfo = LuauOpCode[op]
						if opInfo and string.find(opInfo.name, "JUMP") then
							-- check if matches initial jump point
							local endPoint = i + Luau:INSN_sD(insn)
							if endPoint == jumpEndPoint then
								promotedJumps[i] = true
								promote = true
								break
							else
								break
							end
						end
					end

					if promote then
						table.insert(pointData, POINT_TYPE_ELSEIF)
					else
						table.insert(pointData, POINT_TYPE_ELSE)
					end
				else
					table.insert(pointData, POINT_TYPE_END)
				end

				ifLoopPoints[pointId] = pointData
			end

			local protoId = proto.id
			local protoNumParams = proto.numParams
			local protoTypeInfo = proto.typeinfo
			local protoFlags = proto.flags

			local protoVars = 0

			local function logRegister(t, register)
				local dataTable
				if t == "local" then
					dataTable = localData
					protoVars += 1
				elseif t == "global" then
					dataTable = globalData
				end
				local isLogged = table.find(dataTable, register)
				if not isLogged then
					table.insert(dataTable, register)
				end
				return isLogged
			end
			local function modifyRegister(register, isUpvalue)
				-- parameter registers are preallocated
				if register < protoNumParams then
					return `p{(totalParams - protoNumParams) + register + 1}`
				else
					local starterCount
					if isUpvalue then
						starterCount = 0
					else
						starterCount = totalVars
					end
					return `v{starterCount + depth + register - protoNumParams}`, true
				end
			end

			local function baseHotComments()
				-- not really needed but I feel like it
				local isNative = false
				local isCold = true

				if protoFlags then
					isNative = toboolean(bit32.band(protoFlags, LuauProtoFlag.LPF_NATIVE_MODULE))
					isCold = toboolean(bit32.band(protoFlags, LuauProtoFlag.LPF_NATIVE_COLD))
				end

				local output = ""

				if isNative then
					output ..= "--!native\n"

					if ENABLED_REMARKS.NATIVE_REMARK and isCold then
						output ..= string.format(Strings.DECOMPILER_REMARK, "This function is cold and is not compiled natively")
					end
				end

				return output
			end
			local function baseLocal(register, value)
				local prefix = "local "
				-- previously logged
				if logRegister("local", register) then
					prefix = ""
				end

				local register, isVar = modifyRegister(register)
				if not isVar then
					prefix = ""
				end

				return `{prefix}{register} = {value}`
			end
			local function baseLocals(register, count, value)
				if count > 0 then
					local output = `local `

					for i = 0, count - 1 do
						local usedRegister = register + i
						logRegister("local", usedRegister)
						output ..= modifyRegister(usedRegister)
						if i ~= count - 1 then
							output ..= ", "
						end
					end

					output ..= ` = {value}`

					return output
				else
					return baseLocal(register, value)
				end
			end
			local function baseGlobal(key, value)
				logRegister("global", key)

				return `{key} = {value}`
			end
			local function baseFunc()
				local prefix = ""
				local postfix = "function"

				local output

				if proto.source then
					prefix = "local "
					-- has a name
					postfix ..= ` {proto.source}`
				end
				postfix ..= "("

				output = prefix .. postfix

				-- handle type info
				local hasTypedParameters = false
				if protoTypeInfo and #protoTypeInfo > 0 then
					local encodedType = table.remove(protoTypeInfo, 1)
					if (encodedType ~= LuauBytecodeType.LBC_TYPE_FUNCTION) then
						-- this shouldn't happen? but it happened so i had to do this
					else
						local numparams = table.remove(protoTypeInfo, 1)

						hasTypedParameters = true
					end
				end

				-- complex parameter handling
				for i = 1, proto.numParams do
					-- params coincide with stack index
					local paramRef = totalParams + i

					local typeSetString = ""
					if hasTypedParameters then
						local paramType = protoTypeInfo[i]
						if paramType then
							typeSetString ..= `: {Luau:GetBaseTypeString(paramType, true)}`
						end
					end

					output ..= `p{paramRef}{typeSetString}`

					if i < proto.numParams then
						output ..= ", "
					end
				end
				totalParams = totalParams + proto.numParams

				if proto.isVarArg then
					if proto.numParams > 0 then
						output ..= ", "
					end

					output ..= "..."
				end

				output ..= `) {`-- [line {proto.lineDefined}]`}\n`
				output ..= baseHotComments()

				return output
			end

			--

			local protoOutput = ""

			local function addTab(depth)
				protoOutput ..= string.rep("	", depth)
			end
			local function addNewLine()
				protoOutput ..= "\n"
			end

			if isMainProto then
				protoOutput ..= baseHotComments()
			else
				protoOutput ..= baseFunc()

				depth += 1
			end

			-- instruction handling here
			local expectation
			local nextIsAux = false

			for insnIndex, insn in proto.insnTable do
				if nextIsAux then
					nextIsAux = false
				else
					addTab(depth)

					local aux = proto.insnTable[insnIndex + 1]

					local OP = Luau:INSN_OP(insn)
					local A, B, C = Luau:INSN_A(insn), Luau:INSN_B(insn), Luau:INSN_C(insn)
					local D, sD = Luau:INSN_D(insn), Luau:INSN_sD(insn)
					local E = Luau:INSN_E(insn)

					local opInfo = LuauOpCode[OP]
					if not opInfo then
						protoOutput ..= `UNKNOWN OP: {OP}`
						addNewLine()
						continue
					end

					if opInfo.aux then
						nextIsAux = true
					end

					local lineStr = ""

					local remarkProtoName = inlineRemarks[insnIndex..insn]
					if remarkProtoName then
						lineStr ..=  string.format(Strings.DECOMPILER_REMARK, `Function "{remarkProtoName}" was inlined here (LINE IS NOT VALID)`) .. "	"
					end

					if SHOW_INSTRUCTION_LINES then
						local instructionLine = proto.smallLineInfo[insnIndex]
						local instructionLargeLine = proto.largeLineInfo[insnIndex]
						lineStr ..= `[line {instructionLargeLine + instructionLine}] `
					end

					protoOutput ..= lineStr .. tostring(insnIndex) .. "."

					addTab(1)

					if SHOW_OPERATION_NAMES then
						protoOutput ..= opInfo.name or "[UNNAMED]"
						addTab(1)
					end

					-- no scope/flow control

					--local upvalRefs = {}
					--upvalRefData[protoId] = upvalRefs

					local function addReference(refStart, refEnd)
						for _, v in refData do
							if v.insnIndex == refEnd then
								table.insert(v.refs, refStart)
								return
							end
						end

						table.insert(refData, { ["insnIndex"] = refEnd, ["refs"] = {refStart} })
					end

					local nilValue = { ["type"] = "nil", ["value"] = nil }

					--
					local function handleConstantValue(k)
						if k["type"] == LuauBytecodeTag.LBC_CONSTANT_VECTOR then
							return k.value
						else
							if type(tonumber(k.value)) == "number" then
								return tonumber(string.format(`%0.{READER_FLOAT_PRECISION}f`, k.value))
							else
								return toEscapedString(k.value)
							end
						end
					end
					--

					local opConstructors = {} do
						opConstructors["LOADNIL"] = function()
							protoOutput ..= baseLocal(A, "nil")
						end
						opConstructors["NOP"] = function()
							protoOutput ..= "[NOP]"
						end
						opConstructors["BREAK"] = function()
							protoOutput ..= "break (debugger)"
						end
						opConstructors["LOADK"] = function()
							local k = proto.constsTable[D + 1] or nilValue
							protoOutput ..= baseLocal(A, handleConstantValue(k))
						end
						opConstructors["LOADKX"] = function()
							local k = proto.constsTable[aux + 1] or nilValue
							protoOutput ..= baseLocal(A, handleConstantValue(k))
						end
						opConstructors["LOADB"] = function()
							local value = toboolean(B)
							protoOutput ..= baseLocal(A, toEscapedString(value))
							if C ~= 0 then
								protoOutput ..= string.format(" +%i", C) -- skip over next LOADB?
							end
						end
						opConstructors["LOADN"] = function()
							protoOutput ..= baseLocal(A, sD)
						end
						opConstructors["GETUPVAL"] = function()
							--local upvalRefs = upvalRefData[protoId - 1] or {}

							--local var = upvalRefs[B]
							--if var then
							--	protoOutput ..= baseLocal(A, toEscapedString(var))
							--else
							--	protoOutput ..= baseLocal(A, `upvalues[{B}]`)
							--end
							protoOutput ..= baseLocal(A, `{proto.nestedUpvalues[B]} -- get upval`)
						end
						opConstructors["SETUPVAL"] = function()
							protoOutput ..= `{proto.nestedUpvalues[B]} = {modifyRegister(A)} -- set upval`
						end
						opConstructors["CLOSEUPVALS"] = function()
							protoOutput ..= `[CLOSEUPVALS]: clear captures from back until: {A}`
						end
						opConstructors["MOVE"] = function()
							protoOutput ..= baseLocal(A, modifyRegister(B))
						end
						opConstructors["MINUS"] = function()
							protoOutput ..= baseLocal(A, `-{modifyRegister(B)}`)
						end
						opConstructors["LENGTH"] = function()
							protoOutput ..= baseLocal(A, `#{modifyRegister(B)}`)
						end
						opConstructors["NOT"] = function()
							protoOutput ..= baseLocal(A, `not {modifyRegister(B)}`)
						end
						opConstructors["GETVARARGS"] = function()
							protoOutput ..= baseLocals(A, B - 1, "...")
						end
						opConstructors["CONCAT"] = function()
							local value = modifyRegister(B)
							local totalStrings = C - B
							for i = 1, totalStrings do
								value ..= ` .. {modifyRegister(B + i)}`
							end
							protoOutput ..= baseLocal(A, value)
						end
						opConstructors["AND"] = function()
							protoOutput ..= baseLocal(A, `{modifyRegister(B)} and {modifyRegister(C)}`)
						end
						opConstructors["OR"] = function()
							protoOutput ..= baseLocal(A, `{modifyRegister(B)} or {modifyRegister(C)}`)
						end
						opConstructors["ANDK"] = function()
							local k = proto.constsTable[C + 1] or nilValue
							protoOutput ..= baseLocal(A, `{modifyRegister(B)} and {handleConstantValue(k)}`)
						end
						opConstructors["ORK"] = function()
							local k = proto.constsTable[C + 1] or nilValue
							protoOutput ..= baseLocal(A, `{modifyRegister(B)} or {handleConstantValue(k)}`)
						end
						opConstructors["FASTCALL"] = function()
							protoOutput ..= `FASTCALL[{Luau:GetBuiltinInfo(A)}]()`
						end
						opConstructors["FASTCALL1"] = function()
							protoOutput ..= `FASTCALL[{Luau:GetBuiltinInfo(A)}]({modifyRegister(B)})`
						end
						opConstructors["FASTCALL2"] = function()
							protoOutput ..= `FASTCALL[{Luau:GetBuiltinInfo(A)}]({modifyRegister(B)}, {modifyRegister(aux)})`
						end
						opConstructors["FASTCALL2K"] = function()
							local k = proto.constsTable[aux + 1] or nilValue
							protoOutput ..= `FASTCALL[{Luau:GetBuiltinInfo(A)}]({modifyRegister(B)}, {handleConstantValue(k)})`
						end
						opConstructors["GETIMPORT"] = function()
							local indexCount = rshift(aux, 30) -- 0x40000000 --> 1, 0x80000000 --> 2

							local cacheIndex1 = bit32.band(rshift(aux, 20), 0x3FF)
							local cacheIndex2 = bit32.band(rshift(aux, 10), 0x3FF)
							local cacheIndex3 = bit32.band(rshift(aux, 0), 0x3FF)

							if indexCount == 1 then
								local k1 = tostring(proto.constsTable[cacheIndex1 + 1].value)
								if not isGlobal(k1) then
									logRegister("global", k1)
								end
								protoOutput ..= baseLocal(A, k1)
							elseif indexCount == 2 then
								local k1 = tostring(proto.constsTable[cacheIndex1 + 1].value)
								local k2 = tostring(proto.constsTable[cacheIndex2 + 1].value)
								protoOutput ..= baseLocal(A, `{k1}{formatIndexString(k2)}`)
							elseif indexCount == 3 then
								local k1 = tostring(proto.constsTable[cacheIndex1 + 1].value)
								local k2 = tostring(proto.constsTable[cacheIndex2 + 1].value)
								local k3 = tostring(proto.constsTable[cacheIndex3 + 1].value)
								protoOutput ..= baseLocal(A, `{k1}{formatIndexString(k2)}{formatIndexString(k3)}`)
							else
								error("[GETIMPORT] Too many entries")
							end
						end
						opConstructors["GETGLOBAL"] = function()
							local k = proto.constsTable[aux + 1] or nilValue
							local key = tostring(k.value) -- escaping not required here
							logRegister("global", key)
							protoOutput ..= baseLocal(A, key)
						end
						opConstructors["SETGLOBAL"] = function()
							local k = proto.constsTable[aux + 1] or nilValue
							local key = tostring(k.value)
							protoOutput ..= baseGlobal(key, modifyRegister(A))
						end
						opConstructors["GETTABLE"] = function()
							protoOutput ..= baseLocal(A, `{modifyRegister(B)}[{modifyRegister(C)}]`)
						end
						opConstructors["SETTABLE"] = function()
							protoOutput ..= `{modifyRegister(B)}[{modifyRegister(C)}] = {modifyRegister(A)}`
						end
						opConstructors["GETTABLEN"] = function()
							protoOutput ..= baseLocal(A, `{modifyRegister(B)}[{C - 1}]`)
						end
						opConstructors["SETTABLEN"] = function()
							protoOutput ..= `{modifyRegister(B)}[{C - 1}] = {modifyRegister(A)}`
						end
						opConstructors["GETTABLEKS"] = function()
							local k = proto.constsTable[aux + 1] or nilValue
							protoOutput ..= baseLocal(A, `{modifyRegister(B)}{formatIndexString(k.value)}`)
						end
						opConstructors["SETTABLEKS"] = function()
							local k = proto.constsTable[aux + 1] or nilValue
							protoOutput ..= `{modifyRegister(B)}{formatIndexString(k.value)} = {modifyRegister(A)}`
						end
						opConstructors["NAMECALL"] = function()
							local k = proto.constsTable[aux + 1] or nilValue
							expectation = { ["type"] = "NAMECALL", ["value"] = `{modifyRegister(B)}:{tostring(k.value)}` }
							--nextIsAux = true
						end
						opConstructors["FORNPREP"] = function() -- prepare numeric loop
							--TODO: read instructions before fornprep and show their values (and clear them away)
							-- also remove step if its 1
							protoOutput ..= `for {modifyRegister(A + 2)} = {modifyRegister(A + 2)}, {modifyRegister(A)}, {modifyRegister(A + 1)} do -- [escape at #{insnIndex + sD}]`
						end
						opConstructors["FORNLOOP"] = function()
							protoOutput ..= "end" .. ` -- FORNLOOP end - iterate + goto #{insnIndex + sD}`
						end
						opConstructors["FORGPREP"] = function() -- prepare generic loop
							local endInsnIndex = insnIndex + sD + 1
							local endInsnAuxIndex = endInsnIndex + 1
							local endInsnAux = proto.insnTable[endInsnAuxIndex]

							local numRegs = bit32.band(endInsnAux, 0xFF)

							local regStr = ""
							for regIndex = 1, numRegs do
								regStr = regStr .. modifyRegister(A + 2 + regIndex)
								if regIndex ~= numRegs then
									regStr = regStr .. ", "
								end
							end

							protoOutput ..= `for {regStr} in {modifyRegister(A)} do -- [escape at #{endInsnIndex}]`
						end
						opConstructors["FORGLOOP"] = function()
							local respectsArrayOrder = toboolean(rshift(aux, 0x1F))
							protoOutput ..= "end" .. string.format(" -- FORGLOOP - iterate + goto #%i", insnIndex + sD) .. (respectsArrayOrder and " (ipairs)" or "")
						end
						opConstructors["FORGPREP_INEXT"] = function()
							local endInsnIndex = insnIndex + sD + 1
							local endInsnAuxIndex = endInsnIndex + 1
							local endInsnAux = proto.insnTable[endInsnAuxIndex]

							local numRegs = bit32.band(endInsnAux, 0xFF)

							local regStr = ""
							for regIndex = 1, numRegs do
								regStr = regStr .. modifyRegister(A + 2 + regIndex)
								if regIndex ~= numRegs then
									regStr = regStr .. ", "
								end
							end

							protoOutput ..= `for {regStr} in {modifyRegister(A)}({modifyRegister(A + 1)}) do -- [escape at #{endInsnIndex}] (ipairs)`
						end
						opConstructors["DEP_FORGLOOP_INEXT"] = function()
							local endInsnIndex = insnIndex + sD + 1
							local endInsnAuxIndex = endInsnIndex + 1
							local endInsnAux = proto.insnTable[endInsnAuxIndex]

							local numRegs = bit32.band(endInsnAux, 0xFF)

							local regStr = ""
							for regIndex = 1, numRegs do
								regStr = regStr .. modifyRegister(A + 2 + regIndex)
								if regIndex ~= numRegs then
									regStr = regStr .. ", "
								end
							end

							protoOutput ..= `for {regStr} in {modifyRegister(A)}({modifyRegister(A + 1)}) do -- [escape at #{endInsnIndex}] (ipairs) DEPRECATED`
						end
						opConstructors["FORGPREP_NEXT"] = function()
							local endInsnIndex = insnIndex + sD + 1
							local endInsnAuxIndex = endInsnIndex + 1
							local endInsnAux = proto.insnTable[endInsnAuxIndex]

							local numRegs = bit32.band(endInsnAux, 0xFF)

							local regStr = ""
							for regIndex = 1, numRegs do
								regStr = regStr .. modifyRegister(A + 2 + regIndex)
								if regIndex ~= numRegs then
									regStr = regStr .. ", "
								end
							end

							protoOutput ..= `for {regStr} in {modifyRegister(A)}({modifyRegister(A + 1)}) do -- [escape at #{endInsnIndex}] (pairs/next)`
						end
						opConstructors["DEP_FORGLOOP_NEXT"] = function()
							local endInsnIndex = insnIndex + sD + 1
							local endInsnAuxIndex = endInsnIndex + 1
							local endInsnAux = proto.insnTable[endInsnAuxIndex]

							local numRegs = bit32.band(endInsnAux, 0xFF)

							local regStr = ""
							for regIndex = 1, numRegs do
								regStr = regStr .. modifyRegister(A + 2 + regIndex)
								if regIndex ~= numRegs then
									regStr = regStr .. ", "
								end
							end

							protoOutput ..= `for {regStr} in {modifyRegister(A)}({modifyRegister(A + 1)}) do -- [escape at #{endInsnIndex}] (pairs/next) DEPRECATED`
						end
						opConstructors["JUMP"] = function()
							local endPoint = insnIndex + sD
							createLoopPoint(insnIndex, endPoint)
							addReference(insnIndex, endPoint)
							protoOutput ..= string.format("goto #%i", endPoint)
						end
						opConstructors["JUMPBACK"] = function()
							local endPoint = insnIndex + sD
							createLoopPoint(insnIndex, endPoint)
							addReference(insnIndex, endPoint)
							protoOutput ..= string.format("go back to #%i -- might be a repeating loop", endPoint + 1)
						end
						opConstructors["JUMPIF"] = function(ignoreJump) -- inverse
							local nextInsn = proto.insnTable[insnIndex + 2]
							local nextOP = Luau:INSN_OP(nextInsn)
							if not ignoreJump and LuauOpCode[nextOP] and LuauOpCode[nextOP].name == "JUMPBACK" then
								return opConstructors["JUMPIFNOT"](true)
							end
							local endPoint = insnIndex + sD
							createLoopPoint(insnIndex, endPoint)
							addReference(insnIndex, endPoint)
							protoOutput ..= string.format("if not %s then goto #%i", modifyRegister(A), endPoint)
						end
						opConstructors["JUMPIFNOT"] = function(ignoreJump) -- inverse
							local nextInsn = proto.insnTable[insnIndex + 2]
							local nextOP = Luau:INSN_OP(nextInsn)
							if not ignoreJump and LuauOpCode[nextOP] and LuauOpCode[nextOP].name == "JUMPBACK" then
								return opConstructors["JUMPIF"](true)
							end
							local endPoint = insnIndex + sD
							createLoopPoint(insnIndex, endPoint)
							addReference(insnIndex, endPoint)
							protoOutput ..= string.format("if %s then goto #%i", modifyRegister(A), endPoint)
						end
						opConstructors["JUMPX"] = function()
							addReference(insnIndex, insnIndex + E)
							protoOutput ..= string.format("goto #%i [X]", insnIndex + E)
						end
						opConstructors["JUMPIFEQ"] = function(ignoreJump) -- inverse
							local nextInsn = proto.insnTable[insnIndex + 2]
							local nextOP = Luau:INSN_OP(nextInsn)
							if not ignoreJump and LuauOpCode[nextOP] and LuauOpCode[nextOP].name == "JUMPBACK" then
								return opConstructors["JUMPIFNOTEQ"](true)
							end
							local endPoint = insnIndex + sD
							createLoopPoint(insnIndex, endPoint)
							addReference(insnIndex, endPoint)
							protoOutput ..= string.format("if %s ~= %s then goto #%i", modifyRegister(A), modifyRegister(aux), endPoint)
