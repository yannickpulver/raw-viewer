-- resolve_export.lua
--
-- Runs under DaVinci Resolve's bundled Lua 5.1 interpreter:
--
--   fuscript -l lua resolve_export.lua <projectName> <jobFile>
--
-- The job file has one line per media file: "<rating>\t<absolute path>".
--
-- Output protocol (tab separated, one line each, flushed immediately):
--   STATUS\t<text>                     progress for the UI
--   RESULT\tOK\t<clipCount>\t<rated>   success
--   RESULT\tERR\t<message>             failure (single line)
--   NOTRUNNING                         bmd.scriptapp("Resolve") returned nil
--
-- The rating -> colour / keyword / Good Take mapping below is the user-visible
-- contract (spec 06 section 4). It is mirrored in ResolveExport.ratingMapping
-- in Swift, which is unit tested; keep the two in sync.

local RATING_MAP = {
  [1] = { color = "Blue",   keywords = "1star",         goodTake = false, comments = "Rating: 1/5", description = "★☆☆☆☆" },
  [2] = { color = "Teal",   keywords = "2stars",        goodTake = false, comments = "Rating: 2/5", description = "★★☆☆☆" },
  [3] = { color = "Yellow", keywords = "3stars",        goodTake = false, comments = "Rating: 3/5", description = "★★★☆☆" },
  [4] = { color = "Orange", keywords = "4stars",        goodTake = true,  comments = "Rating: 4/5", description = "★★★★☆" },
  [5] = { color = "Green",  keywords = "5stars,keeper", goodTake = true,  comments = "Rating: 5/5", description = "★★★★★" },
}

local function emit(line)
  io.stdout:write(line .. "\n")
  io.stdout:flush()
end

local function status(text)
  emit("STATUS\t" .. text)
end

local function resultOK(clips, rated)
  emit("RESULT\tOK\t" .. tostring(clips) .. "\t" .. tostring(rated))
end

local function resultErr(message)
  message = tostring(message):gsub("[\r\n\t]", " ")
  emit("RESULT\tERR\t" .. message)
end

local function basename(path)
  return (tostring(path):match("([^/]+)$")) or tostring(path)
end

-- Reads the job file. Returns an ordered list of paths, a path -> rating map
-- and a basename -> rating map (fallback matching only).
local function readJob(jobFile)
  local paths, byPath, byName = {}, {}, {}
  for line in io.lines(jobFile) do
    if line ~= "" then
      local tab = line:find("\t", 1, true)
      if tab then
        local rating = tonumber(line:sub(1, tab - 1)) or 0
        local path = line:sub(tab + 1)
        if path ~= "" then
          paths[#paths + 1] = path
          byPath[path] = rating
          byName[basename(path)] = rating
        end
      end
    end
  end
  return paths, byPath, byName
end

local function run()
  local projectName = arg and arg[1]
  local jobFile = arg and arg[2]
  if not projectName or projectName == "" then
    resultErr("Missing project name argument.")
    return
  end
  if not jobFile or jobFile == "" then
    resultErr("Missing job file argument.")
    return
  end

  local resolve = bmd.scriptapp("Resolve")
  if not resolve then
    emit("NOTRUNNING")
    return
  end

  local paths, byPath, byName = readJob(jobFile)
  if #paths == 0 then
    resultErr("No files were imported. Check file formats.")
    return
  end

  status("Creating project...")
  local pm = resolve:GetProjectManager()
  if not pm then
    resultErr("Could not access Project Manager.")
    return
  end

  local project = pm:CreateProject(projectName)
  if not project then
    project = pm:LoadProject(projectName)
  end
  if not project then
    resultErr("Could not create or load project '" .. projectName .. "'.")
    return
  end

  status("Importing " .. tostring(#paths) .. " files...")
  local mediaPool = project:GetMediaPool()
  if not mediaPool then
    resultErr("Could not access Media Pool.")
    return
  end

  local clips = mediaPool:ImportMedia(paths)
  if not clips or #clips == 0 then
    resultErr("No files were imported. Check file formats.")
    return
  end

  status("Setting metadata on " .. tostring(#clips) .. " clips...")
  local rated = 0
  for _, clip in ipairs(clips) do
    -- Match by file path, not by name: two cards can hold the same filename.
    local filePath = clip:GetClipProperty("File Path")
    local rating = nil
    if filePath and filePath ~= "" then
      rating = byPath[filePath]
    end
    if rating == nil then
      local name = clip:GetName()
      if name and name ~= "" then
        rating = byName[name]
      end
    end

    local map = rating and RATING_MAP[rating] or nil
    if map then
      clip:SetClipColor(map.color)
      clip:SetMetadata({
        ["Keywords"] = map.keywords,
        ["Comments"] = map.comments,
        ["Description"] = map.description,
      })
      if map.goodTake then
        clip:SetMetadata("Good Take", "true")
      end
      rated = rated + 1
    end
  end

  project:SaveProject()
  resultOK(#clips, rated)
end

local ok, err = pcall(run)
if not ok then
  resultErr("Resolve script error: " .. tostring(err))
end
