--- HELPERS ---
local function readFlagPart(byte, pos, count)
  return (byte>>pos)&(2^count-1)
end
local function readBits(str, index, count)
  local pos, n, wo, rc = math.floor(index*0.125+1), 0, 0
  index = index%8
  while count > 0 do
    rc = math.min(8-index, count)
    n = n | (((str:byte(pos)>>index)&(2^rc-1)) << wo)
    wo = rc
    
    pos = pos+1
    index = 0
    count = count-rc
  end
  return n
end
local function toColorArray(str, count)
  local t, r, g, b = {}
  for i=0,count-1 do
    r, g, b = str:byte(i*3+1, i*3+3)
    t[i] = r*65536+g*256+b
  end
  return t
end

--- IMAGE READ ---
local function readImgBlock(dict, dictIndex, clear, stop, index, wordLen, wordFull, wordMin, str, strLen)
  local part, max, prevPart, ind, ps, cs = {}, strLen*8, ""
  while true do
    if index+wordLen >= max then break end
    ind = readBits(str, index, wordLen)
    if ind == stop then break
    elseif ind == clear then
      index = index+wordLen
      dictIndex = stop+1
      wordLen = wordMin
      wordFull = 2^wordLen-1
    else
      if ind >= dictIndex then
        ps = prevPart..prevPart:sub(1,1)
        table.insert(part, ps)
        prevPart = ps
      else
        cs = dict[ind]
        ps = prevPart..cs:sub(1,1)
        table.insert(part, cs)
        prevPart = cs
      end
      dict[dictIndex] = ps
      index = index+wordLen
      if dictIndex > wordFull then
        wordLen = wordLen+1
        wordFull = 2^wordLen-1
      end
      dictIndex = dictIndex+1
    end
  end
  return table.concat(part, ""), dictIndex, index, wordLen, wordFull
end
local function readImage(stream, struct, tmpExt)
  local img = {}
  local str = stream:read(9)
  img.x = str:byte(1) + str:byte(2)*256
  img.y = str:byte(3) + str:byte(4)*256
  img.width = str:byte(5) + str:byte(6)*256
  img.height = str:byte(7) + str:byte(8)*256
  img.extensions = tmpExt
  
  local flags = str:byte(9)
  img.interlaced = readFlagPart(flags, 6, 1) == 1
  if readFlagPart(flags, 7, 1) == 1 then
    img.colorsCount = 2^(readFlagPart(flags, 0, 3)+1)
    img.colors = toColorArray(stream:read(img.colorsCount*3), img.colorsCount)
  end
  
  str = stream:read(2)
  local lzwMin = str:byte(1)+1
  
  local dict = {}
  local dictIndex = 0
  for i=1,(img.colorsCount or struct.colorsCount or 256) do
    dict[dictIndex] = string.char(i-1)
    dictIndex = dictIndex+1
  end
  
  local clear, stop = dictIndex, dictIndex+1
  dictIndex = dictIndex+2
  
  local bitIndex = 0
  local wordLen, wordFull = lzwMin, 2^lzwMin-1
  
  local data, part = ""
  local len = str:byte(2)
  str = ""
  repeat
    str = str:sub(math.floor(bitIndex*0.125)+1, str:len())..stream:read(len)
    bitIndex = bitIndex%8
    part, dictIndex, bitIndex, wordLen, wordFull = readImgBlock(dict, dictIndex, clear, stop, bitIndex, wordLen, wordFull, lzwMin, str, str:len())
    data = data..part
    len = stream:read(1):byte()
  until len == 0
  img.pixels = data
  return img
end

--- BLOCKS READ ---
local function readExtension(id, stream, tmpExt)
  local len
  if id == 0xF9 then
    len = stream:read(1):byte()
    local str = stream:read(len)
    local flags = str:byte(1)
    local ext = {}
    ext.dispMethod = readFlagPart(flags, 2, 3)
    ext.delay = str:byte(2) + str:byte(3)*256
    ext.inputFlag = readFlagPart(flags, 6, 1) == 1
    if readFlagPart(flags, 7, 1) == 1 then
      ext.transparentIndex = str:byte(4)
    end
    if not tmpExt then tmpExt = {} end
    tmpExt.graphics = ext
  elseif id == 0xFF then
    len = stream:read(1):byte()
    local str = stream:read(len)
    if str:sub(1, 11) == "NETSCAPE2.0" then
      len = stream:read(1):byte()
      str = stream:read(len)
      local ext = {}
      ext.iterations = str:byte(2) + str:byte(3)*256
      ext.loop = ext.iterations == 0
      if not tmpExt then tmpExt = {} end
      tmpExt.app = ext
    end
  elseif id == 0x01 then
    len = stream:read(1):byte()
    local str = stream:read(len)
    local ext = {}
    ext.x = str:byte(1) + str:byte(2)*256
    ext.y = str:byte(3) + str:byte(4)*256
    ext.width = str:byte(5) + str:byte(6)*256
    ext.height = str:byte(7) + str:byte(8)*256
    ext.charWidth = str:byte(9)
    ext.charHeight = str:byte(10)
    ext.fgIndex = str:byte(11)
    ext.bgIndex = str:byte(12)
    local textParts = {}
    repeat
      len = stream:read(1):byte()
      if len > 0 then table.insert(textParts, stream:read(len)) end
    until len == 0
    ext.text = table.concat(textParts, "")
    tmpExt.text = ext
    return tmpExt
  end -- commment block?
  repeat -- skip other
    len = stream:read(1):byte()
    if len > 0 then stream:seek("cur", len) end
  until len == 0
  return tmpExt
end
local function readBlock(id, stream, struct, tmpExt)
  if id == 0x21 then -- extension
    local str = stream:read(1)
    return readExtension(str:byte(), stream, tmpExt)
  elseif id == 0x2C then -- image
    return readImage(stream, struct, tmpExt)
  end
end

local function readBase(stream, pos)
  if not pos then pos = 0 end
  stream:seek("set", pos)
  local str = stream:read(3)
  if str == "GIF" then
    stream:seek("cur", 3)
    local struct = {}
    str = stream:read(7)
    struct.width = str:byte(1) + str:byte(2)*256
    struct.height = str:byte(3) + str:byte(4)*256
    local flags = str:byte(5)
    --struct.colorBits = readFlagPart(flags, 4, 3)+1
    struct.bgIndex = str:byte(6)
    struct.aspectRatio = str:byte(7)
    if readFlagPart(flags, 7, 1) == 1 then
      struct.colorsCount = 2^(readFlagPart(flags, 0, 3)+1)
      struct.colors = toColorArray(stream:read(struct.colorsCount*3), struct.colorsCount)
    end
    return struct
  end
  return nil, "invalid format"
end

--- GIF INTERFACE ---
local gif = {}
function gif.read(stream, pos)
  local struct, err = readBase(stream, pos)
  if not struct then return nil, err end
  
  local tmp, id
  struct.images = {}
  repeat
    id = stream:read(1):byte()
    tmp = readBlock(id, stream, struct, tmp)
    if id == 0x2C then
      table.insert(struct.images, tmp)
      tmp = nil
    end
  until id == 0x3B -- end of file
  return struct
end
function gif.parts(stream, pos)
  local struct, err = readBase(stream, pos)
  if not struct then return nil, err end
  
  local tmp, id, img
  return function()
    while true do
      id = stream:read(1):byte()
      if id == 0x3B then return nil end -- end of file
      
      tmp = readBlock(id, stream, struct, tmp)
      if id == 0x2C then
        img, tmp = tmp, nil
        return struct, img
      end
    end
  end
end
return gif