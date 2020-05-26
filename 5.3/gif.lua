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
local function readImgBlock(dict, dictIndex, clear, stop, index, wordLen, wordFull, wordMin, str, strLen, prevPart)
  local part, partInd, max, ind, cs = {}, 1, strLen*8
  while true do
    if dictIndex > wordFull then
      wordLen = wordLen+1
      wordFull = 2^wordLen-1
    end
    if index+wordLen >= max then break end
    ind = readBits(str, index, wordLen)
    if ind == stop then break
    elseif ind == clear then
      index = index+wordLen
      dictIndex = stop+1
      wordLen = wordMin
      wordFull = 2^wordLen-1
      prevPart = nil
    else
      if ind >= dictIndex then
        cs = prevPart..prevPart:sub(1,1)
        part[partInd] = cs
        partInd = partInd+1
        dict[dictIndex] = cs
        dictIndex = dictIndex+1
      else
        cs = dict[ind]
        part[partInd] = cs
        partInd = partInd+1
        if prevPart then
          dict[dictIndex] = prevPart..cs:sub(1,1)
          dictIndex = dictIndex+1
        end
      end
      index = index+wordLen
      prevPart = cs
    end
  end
  return table.concat(part, ""), dictIndex, index, wordLen, wordFull, prevPart
end
local function readImage(stream, struct)
  local img = {}
  local str = stream:read(9)
  img.x = str:byte(1) + str:byte(2)*256
  img.y = str:byte(3) + str:byte(4)*256
  img.width = str:byte(5) + str:byte(6)*256
  img.height = str:byte(7) + str:byte(8)*256
  
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
  
  local data, part, prevPart = ""
  local len = str:byte(2)
  str = ""
  repeat
    str = str:sub(math.floor(bitIndex*0.125)+1, str:len())..stream:read(len)
    bitIndex = bitIndex%8
    part, dictIndex, bitIndex, wordLen, wordFull, prevPart = readImgBlock(dict, dictIndex, clear, stop, bitIndex, wordLen, wordFull, lzwMin, str, str:len(), prevPart)
    data = data..part
    len = stream:read(1):byte()
  until len == 0
  img.pixels = data
  return img
end

--- BLOCKS READ ---
local function readExtension(id, stream)
  local len, extType, ext
  if id == 0xF9 then
    len = stream:read(1):byte()
    local str = stream:read(len)
    local flags = str:byte(1)
    ext = {}
    ext.dispMethod = readFlagPart(flags, 2, 3)
    ext.delay = (str:byte(2) + str:byte(3)*256)*0.01
    ext.inputFlag = readFlagPart(flags, 6, 1) == 1
    if readFlagPart(flags, 7, 1) == 1 then
      ext.transparentIndex = str:byte(4)
    end
    extType = "graphics"
  elseif id == 0xFF then
    len = stream:read(1):byte()
    local str = stream:read(len)
    if str:sub(1, 11) == "NETSCAPE2.0" then
      len = stream:read(1):byte()
      str = stream:read(len)
      ext = {}
      ext.iterations = str:byte(2) + str:byte(3)*256
      ext.loop = ext.iterations == 0
      extType = "NETSCAPE2.0"
    end
  elseif id == 0x01 then
    len = stream:read(1):byte()
    local str = stream:read(len)
    ext = {}
    ext.x = str:byte(1) + str:byte(2)*256
    ext.y = str:byte(3) + str:byte(4)*256
    ext.width = str:byte(5) + str:byte(6)*256
    ext.height = str:byte(7) + str:byte(8)*256
    ext.charWidth = str:byte(9)
    ext.charHeight = str:byte(10)
    ext.fgIndex = str:byte(11)
    ext.bgIndex = str:byte(12)
    local textParts, partInd = {}, 1
    repeat
      len = stream:read(1):byte()
      if len > 0 then
        textParts[partInd] = stream:read(len)
        partInd = partInd+1
      end
    until len == 0
    ext.text = table.concat(textParts, "")
    return "text", ext
  elseif id == 0xFE then
    local textParts, partInd = {}, 1
    repeat
      len = stream:read(1):byte()
      if len > 0 then
        textParts[partInd] = stream:read(len)
        partInd = partInd+1
      end
    until len == 0
    return "commment", table.concat(textParts, "")
  end
  repeat -- skip other
    len = stream:read(1):byte()
    if len > 0 then stream:seek("cur", len) end
  until len == 0
  return extType, ext
end
local function readBlock(id, stream, struct)
  if id == 0x21 then -- extension
    return readExtension(stream:read(1):byte(), stream)
  elseif id == 0x2C then -- image
    return "image", readImage(stream, struct)
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
    struct.colorBits = readFlagPart(flags, 4, 3)+1
    struct.bgIndex = str:byte(6)
    struct.aspectRatio = str:byte(7)
    if struct.aspectRatio > 0 then struct.aspectRatio = (struct.aspectRatio+15)/64 end
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
  
  struct.extensions = {}
  struct.blocks = {}
  local blockInd, id, bt, bv, imgExt = 1
  repeat
    id = stream:read(1):byte()
    bt, bv = readBlock(id, stream, struct)
    if bt then
      if bt == "graphics" then imgExt = bv
      elseif bt == "NETSCAPE2.0" then struct.extensions[bt] = bv
      else
        if bt == "image" then
          if imgExt then
            bv.extension = imgExt
            imgExt = nil
          end
        end
        struct.blocks[blockInd] = {type=bt, block=bv}
        blockInd = blockInd+1
      end
    end
  until id == 0x3B -- end of file
  return struct
end
function gif.images(stream, pos)
  local struct, err = readBase(stream, pos)
  if not struct then return nil, err end
  
  struct.extensions = {}
  local id, bt, bv, imgExt
  return function()
    while true do
      id = stream:read(1):byte()
      if id == 0x3B then return nil end -- end of file
      
      bt, bv = readBlock(id, stream, struct)
      if bt then
        if bt == "graphics" then imgExt = bv
        elseif bt == "NETSCAPE2.0" then struct.extensions[bt] = bv
        else
          if bt == "image" then
            if imgExt then
              bv.extension = imgExt
              imgExt = nil
            end
            return struct, bv
          end
        end
      end
    end
  end
end
function gif.blocks(stream, pos)
  local struct, err = readBase(stream, pos)
  if not struct then return nil, err end
  
  struct.extensions = {}
  local tmp, id, img
  return function()
    while true do
      id = stream:read(1):byte()
      if id == 0x3B then return nil end -- end of file
      
      bt, bv = readBlock(id, stream, struct)
      if bt then
        if bt == "graphics" then imgExt = bv
        elseif bt == "NETSCAPE2.0" then struct.extensions[bt] = bv
        else
          if bt == "image" then
            if imgExt then
              bv.extension = imgExt
              imgExt = nil
            end
          end
          return struct, bt, bv
        end
      end
    end
  end
end
return gif