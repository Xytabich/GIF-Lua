local gif = {}
local function bitsToNumber(byte, pos, count)
  return (byte>>pos)&(2^count-1)
end
local function toColorArray(str, count)
  local t, r, g, b = {}
  for i=0,count-1 do
    r, g, b = str:byte(i*3+1, i*3+3)
    t[i] = r*65536+g*256+b
  end
  return t
end
local function readExtension(id, stream, struct)--todo: записывать расширения в саму картинку, а не в список расширений(т.е. сделать временную переменную extension, которую будет смотреть картинка при декоде)
  local len
  if id == 0xF9 then
    len = stream:read(1):byte()
    local str = stream:read(len)
    local flags = str:byte(1)
    local ext = {}
    ext.dispMethod = bitsToNumber(flags, 2, 3)
    ext.delay = str:byte(2) + str:byte(3)*256
    ext.inputFlag = bitsToNumber(flags, 6, 1) == 1
    if bitsToNumber(flags, 7, 1) == 1 then
      ext.transparentIndex = str:byte(4)
    end
    table.insert(struct.extensions, ext)
  end--todo: читалка текста и анимации кадров
  repeat
    len = stream:read(1):byte()
    if len > 0 then stream:seek("cur", len) end
  until len == 0
end

local function readBits(str, index, count)
  local n, bit = 0, index%8
  local pos, rc = (index-bit)*0.125+1, 0
  while count > 0 do
    n = n << rc
    
    rc = math.min(8-bit, count)
    n = n | (str:byte(pos)>>bit)&(2^rc-1)
    
    pos = pos+1
    bit = 0
    count = count-rc
  end
  return n
end
local function readImgBlock(dict, invDict, dictIndex, clear, stop, index, wordLen, wordMin, wordFull, str, strLen)--todo: сделать контейнер для переменных, ибо тот-же str может жрать память на передачу в аргумент
  local part, max, prevPart, ind, ps = {}, strLen*8, ""
  while true do
    if index+wordLen >= max then break end
    ind = readBits(str, index, wordLen)
    if ind == stop then break
    elseif ind == clear then
      dictIndex = stop+1
      invDict = {}
      for i=1,clear-1 do invDict[dict[i]] = i end
      index = index+wordLen
    else
      if ind>#dict then
        ps = prevPart..prevPart:sub(1,1)
        dict[dictIndex] = ps
        invDict[ps] = dictIndex
        table.insert(part, dict[dictIndex])
        index = index+wordLen
        if dictIndex > wordFull then wordLen=wordLen+1 end
        dictIndex = dictIndex+1
      else
        table.insert(part, dict[ind])
        ps = prevPart..dict[ind]:sub(1,1)
        index = index+wordLen
        if not invDict[ps] then
          dict[dictIndex] = ps
          if dictIndex > wordFull then wordLen=wordLen+1 end
          dictIndex = dictIndex+1
        end
      end
    end
  end
  return table.concat(part, ""), dictIndex, index, wordLen, wordFull, invDict
end
local function readImage(stream, struct)
  local img = {}
  local str = stream:read(9)
  img.x = str:byte(1) + str:byte(2)*256
  img.y = str:byte(3) + str:byte(4)*256
  img.width = str:byte(5) + str:byte(6)*256
  img.height = str:byte(7) + str:byte(8)*256
  
  local flags = str:byte(9)
  img.interlaced = bitsToNumber(flags, 6, 1) == 1
  if bitsToNumber(flags, 7, 1) == 1 then
    img.colorsCount = 2^(bitsToNumber(flags, 0, 3)+1)
    img.colors = toColorArray(stream:read(img.colorsCount*3), img.colorsCount)
  end
  
  str = stream:read(2)
  local lzwMin = str:byte(1)
  
  local dict, invDict = {}, {}
  for i=0,(img.colorsCount or struct.colorsCount or 256)-1 do dict[i] = string.char(i) invDict[dict[i]] = i end
  
  local clear, stop = #dict+1, #dict+2
  local dictIndex, bitIndex = stop+1, 0 -- dictIndex - next entry index
  local wordLen, wordFull = lzwMin, lzwMin^2-1
  
  local data, part = ""
  local len = str:byte(2)
  str = ""
  repeat
    str = str:sub(math.floor(bitIndex*0.125)+1, str:len())..stream:read(len)
    bitIndex = bitIndex%8
    part, dictIndex, index, wordLen, wordFull, invDict = readImgBlock(dict, invDict, dictIndex, clear, stop, bitIndex, wordLen, wordFull, lzwMin, str, str:len())
    data = data..part
    len = stream:read(1):byte()
  until len == 0
  img.pixels = data
  table.insert(struct.images, img)
end
local function readBlock(id, stream, struct)
  if id == 0x21 then -- extension
    local str = stream:read(1)
    readExtension(str:byte(), stream, struct)
  elseif id == 0x2C then -- image
    readImage(stream, struct)
  end
end
function gif.read(stream, pos)
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
    --struct.colorBits = bitsToNumber(flags, 4, 3)+1
    struct.bgIndex = str:byte(6)
    struct.aspectRatio = str:byte(7)
    if bitsToNumber(flags, 7, 1) == 1 then
      struct.colorsCount = 2^(bitsToNumber(flags, 0, 3)+1)
      struct.colors = toColorArray(stream:read(struct.colorsCount*3), struct.colorsCount)
    end
    struct.images = {}
    struct.extensions = {}
    repeat
      str = stream:read(1)
      readBlock(str:byte(), stream, struct)
    until str == ";" -- 0x3B, end of file
    return struct
  end
  return nil, "invalid format"
end
return gif