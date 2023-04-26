-- 4APOH.lua aka opaiSYNC 2023 edition
-- Made by @opai and @rod9

local drag_system = require "neverlose/drag_system"
local clipboard = require "neverlose/clipboard"
local ffi       = require "ffi"
local pui       = require "neverlose/pui"
local base64    = require "neverlose/base64"
local json      = require "neverlose/nl_json"
local hook      = require "neverlose/vmt_hook"
local gradient  = require "neverlose/gradient"

local sidebar   = pui.sidebar("CHARON.lua", "\f<trash-alt>")

-- [[ ************************** FFI (winapi, game, etc) ************************** ]] --
ffi.cdef[[
    // for SMOKE sound
    bool DeleteUrlCacheEntryA(const char* lpszUrlName);
    void* __stdcall URLDownloadToFileA(void* LPUNKNOWN, const char* LPCSTR, const char* LPCSTR2, int a, int LPBINDSTATUSCALLBACK);
    bool __stdcall PlaySoundA(const char* sound, void* mod, unsigned int flags);

    // for configs
    unsigned long __stdcall GetFileAttributesA(const char* lpFileName);
    unsigned long __stdcall GetLastError();

    // for anims
    typedef struct 
    {
        float m[3][4];
    } matrix3x4_t;

    typedef struct 
    {
        matrix3x4_t* bones;
        char padding[8];
        int count;
    } bone_cache_t;

    typedef struct
    {
        float x, y, z;
    } vec3_t;
]]

local urlmon = ffi.load 'UrlMon'
local wininet = ffi.load 'WinInet'
local winmm = ffi.load 'Winmm'

local g_winapi = {}
g_winapi = {
    download_file = function(from, to)
        wininet.DeleteUrlCacheEntryA(from)
        urlmon.URLDownloadToFileA(nil, from, to, 0, 0)
    end,

    directory_exists = function(path)
        local flag = ffi.C.GetFileAttributesA(path)
        if flag == 0xFFFFFFFF then

            -- ERROR_FILE_NOT_FOUND
            local last_error = ffi.C.GetLastError()
            if last_error == 2 then
                return false
            end
        end

        -- FILE_ATTRIBUTE_DIRECTORY
        if bit.band(flag, 0x00000010) ~= 0x00000010 then
            return false
        end

        return true
    end,

    play_sound = function(path)
        winmm.PlaySoundA(path, nil, 1)
    end,
}

local g_interfaces = {}
g_interfaces = {
    panel   = utils.create_interface("vgui2.dll", "VGUI_Panel009"),
    surface = utils.create_interface("vguimatsurface.dll", "VGUI_Surface031"),
}

local g_patterns = {}
g_patterns = {
    set_abs_angles          = utils.opcode_scan("client.dll", "55 8B EC 83 E4 F8 83 EC 64 53 56 57 8B F1 E8"),
    set_abs_origin          = utils.opcode_scan("client.dll", "55 8B EC 83 E4 F8 51 53 56 57 8B F1 E8"),
}

local g_vfuncs = {}
g_vfuncs = {
    play_sound              = utils.get_vfunc("vguimatsurface.dll", "VGUI_Surface031", 82, "void(__thiscall*)(void*, const char*)"),
    get_client_entity       = utils.get_vfunc("client.dll", "VClientEntityList003", 3, "void*(__thiscall*)(void*, int)"),
    get_view_angles         = utils.get_vfunc("engine.dll", "VEngineClient014", 18, "void(__thiscall*)(void*, vec3_t&)"),
    set_mouse_input_enabled = utils.get_vfunc("vgui2.dll", "VGUI_Panel009", 32, "void(__thiscall*)(void*, int, bool)"),
    get_panel_name          = utils.get_vfunc("vgui2.dll", "VGUI_Panel009", 36, "const char*(__thiscall*)(void*, unsigned int)"),

    get_abs_angles          = utils.get_vfunc(11, "vec3_t&(__thiscall*)(void*)"),
    get_abs_origin          = utils.get_vfunc(12, "vec3_t&(__thiscall*)(void*)"),

    set_abs_angles          = ffi.cast("void(__thiscall*)(void*, const vec3_t&)", g_patterns.set_abs_angles),
    set_abs_origin          = ffi.cast("void(__thiscall*)(void*, const vec3_t&)", g_patterns.set_abs_origin)
}

-- [[ ************************** FFI END ************************** ]] --

-- [[ ************************** LUA STRUCTS (ctx, ui vars & other useful info) ************************** ]] --
CONDITIONS_AMOUNT   = 8
CHARON_PATH         = "nl\\CHARON"
CONFIG_KEY          = 0xAF

FNV32_PRIME = 16777619
FNV32_BASIS = 2166136261

DEG_TO_RAD = function(angle)
    return angle * math.pi / 180
end

RAD_TO_DEG = function(radian)
    return radian * 180 / math.pi
end

TIME_TO_TICKS = function(ticks)
    return math.floor(0.5 + ticks / globals.tickinterval)
end

TICKS_TO_TIME = function(ticks)
    return globals.tickinterval * ticks
end

-- ghetto
-- grab default fov value from cfg before lua begins
local CHEAT_FOV = ui.find("Visuals", "World", "Main", "Field of View")

local g_cached_viewmodel_values = vector(
    cvar.viewmodel_offset_x:int(),
    cvar.viewmodel_offset_y:int(),
    cvar.viewmodel_offset_z:int())

local g_cached_viewmodel_fov = cvar.viewmodel_fov:int()

local conditions_t = {
    new = function()
        return {
            override    = nil,
            pitch       = nil, 
            yaw         = nil,
            yaw_base    = nil,
            yaw_jitter  = nil,
            yaw_jitter_angle = nil,
        
            desync = nil,
        }
    end,
}

local drag_data_t = {
    new = function()
        return {
            dragger         = nil,
            border_alpha    = 0.0,
        }
    end,
}

local g_drag_n_drops = {
    watermark   = nil,
    slowdown    = nil,
}

local g_aspect_ratio_values = {}
g_aspect_ratio_values[170] = "16:9"
g_aspect_ratio_values[160] = "16:10"
g_aspect_ratio_values[133] = "4:3"
g_aspect_ratio_values[125] = "5:4"
g_aspect_ratio_values[100] = "1:1"

local g_manual_angles = {}
g_manual_angles["Left"] = -90
g_manual_angles["Right"] = 90
g_manual_angles["Backward"] = 0
g_manual_angles["Forward"] = 180

local g_ui_conditions = {}
g_ui_conditions["Global"] = 1
g_ui_conditions["Standing"] = 2
g_ui_conditions["Moving"] = 3
g_ui_conditions["Air"] = 4
g_ui_conditions["Ducking"] = 5
g_ui_conditions["Air-ducking"] = 6
g_ui_conditions["Walking"] = 7
g_ui_conditions["Defensive"] = 8

local g_utils = {}
g_utils = {
    round = function(number, decimals)
        local power = 10^decimals
        return math.floor(number * power) / power
    end,

    angle_matrix = function(mat, angles)
        local sy = math.sin(DEG_TO_RAD(angles.y))
        local cy = math.cos(DEG_TO_RAD(angles.y))

        local sp = math.sin(DEG_TO_RAD(angles.x))
        local cp = math.cos(DEG_TO_RAD(angles.x))

        local sr = math.sin(DEG_TO_RAD(angles.z))
        local cr = math.cos(DEG_TO_RAD(angles.z))

        mat[0][0] = cp * cy
        mat[1][0] = cp * sy
        mat[2][0] = -sp

        local crcy = cr * cy
        local crsy = cr * sy
        local srcy = sr * cy
        local srsy = sr * sy
        mat[0][1] = sp * srcy - crsy
        mat[1][1] = sp * srsy + crcy
        mat[2][1] = sr * cp

        mat[0][2] = (sp * crcy + srsy)
        mat[1][2] = (sp * crsy - srcy)
        mat[2][2] = cr * cp
    end,

    is_in_selectable = function(var, size, name)
        local valid = false
        for i = 1, size do
            if var:get()[i] == name then
                valid = true
                break
            end
        end

        return valid
    end,

    get_weapon = function(self, ent)
            csweapon = ent:get_player_weapon():get_weapon_info().weapon_name
            weapon = ''
            if csweapon == "weapon_scar20" or "weapon_g3sg1" then
                weapon = "Auto"
            end
            if csweapon == "weapon_ssg08" then
                weapon = "Scout"
            end
            if csweapon == "weapon_awp" then
                weapon = "AWP"
            end
            if csweapon == "weapon_taser" then
                weapon = "Taser"
            end
            if csweapon == "weapon_knife" then
                weapon = "Knife"
            end
            return weapon
        end,

    predict_eyepos = function(self, ent) 
        origin = ent:get_origin()
        velocity = ent.m_vecVelocity
        interval_per_tick = globals.tickinterval

        return origin + velocity * 14 * interval_per_tick
    end,

    print_log = function (log)
        local result = ""
        for _,v in pairs(log) do
            result = result .. "\a"..log[_].color.. log[_].text
        end
        print_raw("\a8ECFFA[CHARON.LUA] ", result)
    end,


    download_resources = function()
        if not g_winapi.directory_exists(CHARON_PATH) then
            files.create_folder(CHARON_PATH)
        else
            g_winapi.download_file('https://cdn.discordapp.com/attachments/1076839682266124298/1079353700193140797/Untitled.wav', CHARON_PATH .. "\\best.wav")
        end
    end,

    -- credits: @INFIRMS
    create_clamped_sine = function(frequency, intensity, offset, current_time)
        return math.sin(frequency * current_time) * intensity + offset
    end,

    xor_chars = function(string, key)
        local out = {}
        for i = 1, #string do
            local c = string:sub(i, i)
            c = string.char(bit.bxor(string.byte(string, i), key))

            table.insert(out, c)
        end
        
        return table.concat(out)
    end,

    fnv32_hash = function(string)
        local value = FNV32_BASIS
        for i = 1, #string do
            local c = string:sub(i, i)

            value = value * FNV32_PRIME
            value = bit.bxor(value, string.byte(string, i))
        end

        return value
    end,    
}

local g_arrays = {}
g_arrays = {
    new_struct = function(size, struct)
        local arr = {}
        for i = 1, size do
            arr[i] = struct.new()
        end
        return arr
    end,

    new_vars = function(size, value)
        local arr = {}
        for i = 1, size do
            arr[i] = value
        end
        return arr
    end
}

local g_globals = {}
g_globals = {
    texture         = render.load_image(network.get("https://i.imgur.com/ZDv0fIh.png"), vector(500, 700)),
    smoke_gif       = render.load_image(network.get("https://cdn.discordapp.com/attachments/1076839682266124298/1079310994024702042/output-onlinegiftools.gif"), vector(750, 450)),

    watermark       = render.load_image(network.get("https://cdn.discordapp.com/attachments/1006227698928062625/1079801495995830393/3dgifmaker29787.gif"), vector(150, 150)),
    CMePt6          = render.load_image(network.get("https://media1.giphy.com/media/v1.Y2lkPTc5MGI3NjExNTBlMzJiMGVhOTI3MWM5ZDZiMjdjNDY3ZDZiNzRkZGE1YjE1OGZiZCZjdD1z/ViCrwgAQGivXuCh0sa/giphy.gif"), vector(150, 150)),

    charon_slowdown = render.load_image(network.get("https://i.imgur.com/xGYz2kO.png"), vector(300, 200)),

    prefix          = "30 watt",
    debug           = true,
    nickname        = common.get_username(),
    local_player    = nil,
    local_weapon    = nil,
    weapon_info     = nil,

    smoke_data = {
        start_smoke     = false,
        smoke_time      = 0,

        end_smoke       = false,
        end_smoke_time  = 0,
        end_smoke_strength = 0.0,
    },

    anims_data = {
        bone_rotation = 0.0,
        cmd_angles = vector(0, 0, 0),
    },
}

local get_lua_version = function()
    return ("1.0.0 [ %s ]"):format(g_globals.prefix)
end

g_utils.download_resources()

local g_tabs = {}
g_tabs = {
    home = {
        opai   = pui.create("\f<home>\r  Home", "\f<tags>\r  KaPTuHKa_DJl9_6yCTA", 1),
        configs = pui.create("\f<home>\r  Home", "\f<check-square>\r  Configs", 1),

        info    = pui.create("\f<home>\r  Home", "\f<wave-square>\r  Info", 2),
        social  = pui.create("\f<home>\r  Home", "\f<share-alt>\r  Social media", 2),

        smoke   = pui.create("\f<home>\r  Home", "\f<joint>\r  IIepEKyP", 2),
    },

    ragebot = {
        main = pui.create("\f<skull>\r  Rage", "\f<bolt>\r  Main", 1),
    },

    anti_aim = {
        main    = pui.create("\f<key>  Anti-Aim", "\f<tooth> Main", 1),
        misc    = pui.create("\f<key>  Anti-Aim", "\f<viruses> Misc", 1),
        
        setup   = pui.create("\f<key>  Anti-Aim", "\f<theater-masks> Preset", 2),
        preset  = pui.create("\f<key>  Anti-Aim", "\f<undo-alt> Setup", 2),
    },

    misc = {
        ui          = pui.create("\f<teeth-open>  Misc", "\f<street-view> UI", 1),
        camera      = pui.create("\f<teeth-open>  Misc", "\f<camera> Camera", 1),

        undercover  = pui.create("\f<teeth-open>  Misc", "\f<brain> Undercover generator", 2),
    }
}

local g_vars = {}
g_vars = {
    create_condition_vars = function(anti_aim, tab)
        anti_aim.override            = tab:switch("Override Global")
        anti_aim.pitch               = tab:combo("Pitch", "Disabled", "Down", "Fake Down", "Fake Up")
        anti_aim.yaw                 = tab:combo("Yaw", "Disabled", "Backward", "Static")
        anti_aim.yaw_base            = tab:combo("Yaw base", "At target", "Local view")

        anti_aim.yaw_jitter          = tab:combo("Yaw jitter", {"Disabled", "Center", "Offset", "Random", "3-way"}, nil, function(gear)
            local elements = {
                offset               = gear:slider("Angle", -180, 180, 0),

                -- settings for 3-way yaw
                way_angle            = gear:combo("Way type", { "Default", "Custom" }),
                
                first_tick           = gear:slider("1st Yaw Tick", -180, 180, 0),
                second_tick          = gear:slider("2nd Yaw Tick", -180, 180, 0),
                third_tick           = gear:slider("3rd Yaw Tick", -180, 180, 0),

                tick_delay           = gear:slider("Tick Delay", 1, 30, 1, 1, 1, "How many ticks you need to wait when new way will be applied"),
                randomize_tick_order = gear:switch("Randomize Ticks Order", false, "Set ways random order\nIncrease chance to break resolver"),
            }

            return elements
        end)

        anti_aim.desync              = tab:switch("Body yaw", false, nil, function(gear)
            local elements = {
                inverter            = gear:switch("Inverter"),
                left_limit          = gear:slider("Left limit", 0, 60),
                right_limit         = gear:slider("Right limit", 0, 60),
                options             = gear:selectable("Options", "Avoid overlap", "Jitter", "Randomize jitter", "Anti Bruteforce"),
                lby_mode            = gear:combo("LBY Mode", "Disabled", "Opposite", "Sway"),
            }

            return elements
        end)
    end,

    home = {
        opai = {
            texture = g_tabs.home.opai:texture(g_globals.texture, vector(240, 290), color(255, 255, 255), "f", 0),
            censor = g_tabs.home.opai:switch("Censor", false, "Hide picture")
        },

        info = {
            label = g_tabs.home.info:label(("\a8ECFFAFF\f<users>\r   Welcome back to CHARON, \v%s\r\n\n\a8ECFFAFF\f<hand-sparkles>\r   Lua version: %s")
                :format(g_globals.nickname, get_lua_version())),
        },

        social = {
            discord = g_tabs.home.social:button("Join our discord!", function()
                panorama.SteamOverlayAPI.OpenExternalBrowserURL("https://discord.gg/KzeyekmWKw")
            end, true),
        },

        smoke = {
            nicotine_amount =  g_tabs.home.smoke:slider("Nicotine amount", 25, 80, 25, nil, "mg"),
            push            =  g_tabs.home.smoke:button("ПЫХНУТЬ", function()
                g_globals.smoke_data.start_smoke    = true
                g_globals.smoke_data.smoke_time     = globals.realtime

                g_globals.smoke_data.end_smoke      = false
                g_globals.smoke_data.end_smoke_time = 0
            end),
        },
    },

    ragebot = {
        main = {
            break_lc_in_air         = g_tabs.ragebot.main:switch("Break LC in air", false, "Turns defensive in air"),
            teleport_in_air         = g_tabs.ragebot.main:switch("Teleport in air", false, nil, function(gear) 
                local elements = {
                    options         = gear:selectable("Weapons", "Auto", "Scout", "AWP", "Taser", "Knife"),
                    only_on_land    = gear:switch("Only on land", false, "Works only if you can land")
                }

                return elements
            end),
        },
    },

    anti_aim = {
        main = {
            enable          = g_tabs.anti_aim.main:switch("Enable"),
        },

        misc = {
            animation_breakers  = g_tabs.anti_aim.misc:selectable("\vAnim\r Breakers", {"Static Legs in air", "Static Legs on Walk", "Break Movement", "Warp on Crouch", "Pitch on Land"}),
            bone_breakers       = g_tabs.anti_aim.misc:selectable("\vBone\r Breakers", {"Upside down Head", "Spinning Head", "Jittering Head", "Spinning Body"}),
            
            freestanding        = g_tabs.anti_aim.misc:switch("Freestanding", false, nil, function(gear) 
                local elements = {
                    options = gear:selectable("Options", "No At-Targets", "No Jitter", "No Body Jitter"),
                }

                return elements
            end),
            forward_fix         = g_tabs.anti_aim.misc:switch("Forward Fix", true, "Fix broken yaw on DT uncharge."),
            forward_fix_label   = g_tabs.anti_aim.misc:label("\aFFD700FF\f<exclamation-triangle> Keep this feature enabled!"),
        },

        manual = {
            direction       = g_tabs.anti_aim.main:combo("Manual Direction", {"Disabled", "Left", "Right", "Backward", "Forward"}, nil, function(gear)
                local elements = {
                    options         = gear:selectable("Options", "No At-Targets", "No Jitter", "No Body Jitter")
                }

                return elements
            end),           
        },

        setup = {
            label               = nil,
            presets             = nil,
            current_conditions  = nil,
            conditions          = nil,
            import_from_global  = nil,
        },
    },

    misc = {
        ui = {
            watermark = {
                enable  = g_tabs.misc.ui:switch("Watermark"),
                x       =  g_tabs.misc.ui:slider("Watermark X", 0, 10000, 0),
                y       =  g_tabs.misc.ui:slider("Watermark Y", 0, 10000, 0),
            },

            crosshair = {
                enable = g_tabs.misc.ui:switch("Crosshair indicators", false, nil, function(gear)
                    local elements = {
                        color               = gear:color_picker("Logo color", color(142, 207, 250, 255)),
                        second_color        = gear:color_picker("Indicators color", color(142, 207, 250, 255)),
                        offset              = gear:slider("Offset", 0, 30, 0, nil, "px"),
                        other_elements      = gear:selectable("Other indications", "Condition", "Damage", "Hitchance"),
                        adjust_pos          = gear:switch("Adjust position in zoom"),
                    }

                    return elements
                end),
            },

            scope = {
                enable = g_tabs.misc.ui:switch("Custom scope lines", false, nil, function(gear)
                    local elements = {
                        color           = gear:color_picker("First color", color(142, 207, 250, 255)),
                        invert_color    = gear:color_picker("Second color", color(0, 0, 0, 0)),
                        size            = gear:slider("Size", 0, 250, 135, nil, "px"),
                        gap             = gear:slider("Gap", 0, 50, 25, nil, "px"),
                    }

                    return elements
                end)
            },

            slowdown = {
                enable = g_tabs.misc.ui:switch("Slowdown indicator", false, nil, function(gear)
                    local elements = {
                        color       = gear:color_picker("Accent color", color(240, 142, 142, 255)),
                    }

                    return elements
                end),

                x       =  g_tabs.misc.ui:slider("Slowdown X", 0, 10000, 0),
                y       =  g_tabs.misc.ui:slider("Slowdown Y", 0, 10000, 0),
            },
        },

        camera = {
            aspect_ratio = g_tabs.misc.camera:switch("Aspect-Ratio", false, nil, function(gear)
                local elements = {
                    amount = gear:slider("Amount", 0, 200, 0, nil, function(raw)
                        return g_aspect_ratio_values[raw] or raw
                    end), 
                    
                    -- fucking cringe (@opai)
                    set_169     = gear:button("  16:9  ", nil, true),
                    set_1610    = gear:button("  16:10  ", nil, true),
                    set_43      = gear:button("  4:3  ", nil, true),
                    set_54      = gear:button(" 5:4 ", nil, true),
                    set_11      = gear:button(" 1:1 ", nil, true),
                }

                return elements
            end),

            custom_fov = g_tabs.misc.camera:switch("Custom FOV", false, nil, function(gear)
                local elements = {
                    amount = gear:slider("Amount", 0, 160, CHEAT_FOV:get(), nil, "°"), 
                }

                return elements
            end),

            custom_viewmodel = g_tabs.misc.camera:switch("Custom viewmodel", false, nil, function(gear)
                local elements = {
                    amount  = gear:slider("FOV", 0, 50, 0, nil, "°"), 

                    x       = gear:slider("X", -10, 10, 0), 
                    y       = gear:slider("Y", -10, 10, 0), 
                    z       = gear:slider("Z", -10, 10, 0), 

                    pitch   = gear:slider("Pitch", -180, 180, 0, nil, "°"), 
                    yaw     = gear:slider("Yaw", -180, 180, 0, nil, "°"), 
                    roll    = gear:slider("Roll", -180, 180, 0, nil, "°"), 

                    aim_at_enemy = gear:switch("Aim on angles"),
                }

                return elements
            end),
        },

        undercover = {
            enable = g_tabs.misc.undercover:switch("Enable", false, nil, function(gear)
                local elements = {
                    symbols = gear:switch("Enable smiles", false, "Add braindead smiles to undercover"),
                }

                return elements
            end),
            
            value       = g_tabs.misc.undercover:input("Undercover", nil),
            generate    = g_tabs.misc.undercover:button("Generate", 2, true),
        },
        
        
        -- vgui_color = g_tabs.misc.main:switch("Custom VGUI color", false, nil, function(gear)
        --     local elements = {
        --         console         = gear:color_picker("Console", color(100, 100, 100, 255)),
        --         serverbrowser   = gear:color_picker("Server Browser", color(100, 100, 100, 255)),
        --     }

        --     return elements
        -- end),
    },

    cheat = {
        dt              = ui.find("Aimbot", "Ragebot", "Main", "Double Tap"),
        dt_mode         = ui.find("Aimbot", "Ragebot", "Main", "Double Tap", "Lag Options"),
        hs              = ui.find("Aimbot", "Ragebot", "Main", "Hide Shots"),
        pitch           = ui.find("Aimbot", "Anti Aim", "Angles", "Pitch"),
        freestanding    = ui.find("Aimbot", "Anti Aim", "Angles", "Freestanding"),
        peek_assist     = ui.find("Aimbot", "Ragebot", "Main", "Peek Assist"),

        rage = {
            hitchance   = ui.find("Aimbot", "Ragebot", "Selection", "Hit Chance"),
            mindamage   = ui.find("Aimbot", "Ragebot", "Selection", "Minimum Damage"),

            baim        = ui.find("Aimbot", "Ragebot", "Safety", "Body Aim"),
            sp          = ui.find("Aimbot", "Ragebot", "Safety", "Safe Points"),
        },

        yaw = {
            angle           = ui.find("Aimbot", "Anti Aim", "Angles", "Yaw"),
            base            = ui.find("Aimbot", "Anti Aim", "Angles", "Yaw", "Base"),
            offset          = ui.find("Aimbot", "Anti Aim", "Angles", "Yaw", "Offset"),
            avoid_backstab  = ui.find("Aimbot", "Anti Aim", "Angles", "Yaw", "Avoid backstab"),            
        },

        yaw_modifier = {
            type            = ui.find("Aimbot", "Anti Aim", "Angles", "Yaw modifier"),
            offset          = ui.find("Aimbot", "Anti Aim", "Angles", "Yaw modifier", "Offset"),
        },

        body_yaw = {
            enable          = ui.find("Aimbot", "Anti Aim", "Angles", "Body yaw"),
            inverter        = ui.find("Aimbot", "Anti Aim", "Angles", "Body yaw", "Inverter"),
            left_limit      = ui.find("Aimbot", "Anti Aim", "Angles", "Body yaw", "Left Limit"),
            right_limit     = ui.find("Aimbot", "Anti Aim", "Angles", "Body yaw", "Right Limit"),
            options         = ui.find("Aimbot", "Anti Aim", "Angles", "Body yaw", "Options"),
            lby_mode        = ui.find("Aimbot", "Anti Aim", "Angles", "Body yaw", "LBY Mode"),
        },

        misc = {
            fake_duck       = ui.find("Aimbot", "Anti Aim", "Misc", "Fake Duck"),
            slow_walk       = ui.find("Aimbot", "Anti Aim", "Misc", "Slow Walk"),
        },

        chams = {
            model_enable   = ui.find("Visuals", "Players", "Self", "Chams", "Model"),
            model_color    = ui.find("Visuals", "Players", "Self", "Chams", "Model", "Color"),

            weapon_enable   = ui.find("Visuals", "Players", "Self", "Chams", "Weapon"),
            weapon_color    = ui.find("Visuals", "Players", "Self", "Chams", "Weapon", "Color"),

            viewmodel_enable   = ui.find("Visuals", "Players", "Self", "Chams", "Viewmodel"),
            viewmodel_color    = ui.find("Visuals", "Players", "Self", "Chams", "Viewmodel", "Color"),
        },

        world = {
            override_zoom_overlay = ui.find("Visuals", "World", "Main", "Override Zoom", "Scope Overlay"),
        }
    }
}

-- [[ ************************** LUA FEATURES ************************** ]] --
local g_import_aa = {
    is_visible      = false,
    import_from     = nil,
    import_table    = nil,
    apply_button    = nil,
}

local g_condition_names = { "Global", "Standing", "Moving", "Air", "Ducking", "Air-ducking", "Walking", "Defensive" }
local g_conditions = {}
g_conditions = {
    -- create anti aim conditions ui vars & add callbacks for update visibility
    init = function()

        -- why the fuck ui elements are nil when i try to use them here?
        -- alright, let's init all this shit by manual :/
        local setup_tab         = g_tabs.anti_aim.setup
        local preset_tab        = g_tabs.anti_aim.preset
        local setup             = g_vars.anti_aim.setup
        local import            = g_import_aa

        setup.presets               = setup_tab:combo("", "None", "Charon Baby", "Charon Plus", "Custom")
        setup.current_conditions    = preset_tab:combo("\vConditions", "Global", "Standing", "Moving", "Air", "Ducking", "Air-ducking", "Walking", "Defensive")
        setup.conditions            = g_arrays.new_struct(CONDITIONS_AMOUNT, conditions_t)
        setup_tab.label             = preset_tab:label("")

        for i = 1, CONDITIONS_AMOUNT do
            local condition_iter = setup.conditions[i]
            g_vars.create_condition_vars(condition_iter, preset_tab, g_condition_names[i])
        end

        import.import_from          = nil
        setup.import_from_global    = preset_tab:button("Import settings", function()
            g_import_aa.is_visible = not g_import_aa.is_visible

            g_import_aa.import_table = {}
            for i = 1, CONDITIONS_AMOUNT do
                if g_ui_conditions[setup.current_conditions:get()] ~= i then
                    table.insert(g_import_aa.import_table, g_condition_names[i])
                end
            end
            
            import.import_from      = preset_tab:combo("\vImport from", g_import_aa.import_table)
            import.apply_button     = preset_tab:button("Apply", function()
                g_import_aa.is_visible = not g_import_aa.is_visible

                local import_index = g_ui_conditions[import.import_from:get()]
                local index = g_ui_conditions[setup.current_conditions:get()]

                if import_index == index then
                    return
                end

                local current_condition = setup.conditions[index]
                local global_condition  = setup.conditions[import_index]

                current_condition.pitch:set(global_condition.pitch:get())
                current_condition.yaw:set(global_condition.yaw:get())
                current_condition.yaw_base:set(global_condition.yaw_base:get())

                local yaw_jitter = global_condition.yaw_jitter
                current_condition.yaw_jitter:set(yaw_jitter:get())
                current_condition.yaw_jitter.offset:set(yaw_jitter.offset:get())
                current_condition.yaw_jitter.way_angle:set(yaw_jitter.way_angle:get())
                current_condition.yaw_jitter.first_tick:set(yaw_jitter.first_tick:get())
                current_condition.yaw_jitter.second_tick:set(yaw_jitter.second_tick:get())
                current_condition.yaw_jitter.third_tick:set(yaw_jitter.third_tick:get())
                current_condition.yaw_jitter.tick_delay:set(yaw_jitter.tick_delay:get())
                current_condition.yaw_jitter.randomize_tick_order:set(yaw_jitter.randomize_tick_order:get())

                local desync = global_condition.desync
                current_condition.desync:set(desync:get())
                current_condition.desync.inverter:set(desync.inverter:get())
                current_condition.desync.left_limit:set(desync.left_limit:get())
                current_condition.desync.right_limit:set(desync.right_limit:get())
                current_condition.desync.options:set(desync.options:get())
                current_condition.desync.lby_mode:set(desync.lby_mode:get())
            end)
        end)
    end,
    
    update = function()
        local setup                 = g_vars.anti_aim.setup
        local misc                  = g_vars.anti_aim.misc
        local setup_tab             = g_tabs.anti_aim.setup
        
        local current_conditions    = setup.current_conditions
        local presets               = setup.presets
        local import                = g_import_aa
        
        if presets:get() ~= "Custom" then
            setup_tab.label:set_name(("\vBuilder\r was disabled due to selected \vPreset\r"):format(presets:get()))
            setup_tab.label:set_visible(true)
        else
            setup_tab.label:set_visible(false)
        end

        current_conditions:set_visible(presets:get() == "Custom")

        misc.forward_fix_label:set_visible(misc.forward_fix:get())
        setup.import_from_global:set_visible(not import.is_visible and presets:get() == "Custom" and current_conditions:get() ~= "Global")

        if import.import_from ~= nil then
            import.import_from:set_visible(import.is_visible)
        end
        
        if import.apply_button ~= nil then
            import.apply_button:set_visible(import.is_visible)
        end
        
        for i = 1, CONDITIONS_AMOUNT do
            local condition_iter = setup.conditions[i]
            local condition_name_iter = g_condition_names[i]

            local condition_jitter = condition_iter.yaw_jitter

            local should_show_ui = function(is_global_var)
                if presets:get() ~= "Custom" or is_global_var and current_conditions:get() == "Global" then
                    return false
                end

                return current_conditions:get() == condition_name_iter
            end

            -- hide "Override" switch on global config
            condition_iter.override:set_visible(should_show_ui(i == 1))

            local other_show_ui         = should_show_ui(false)
            local is_three_way          = other_show_ui and condition_jitter:get() == "3-way"
            local is_default_angle      = is_three_way and condition_jitter.way_angle:get() == "Default"
            local is_custom_angle       = is_three_way and condition_jitter.way_angle:get() == "Custom"

            condition_iter.pitch:set_visible(other_show_ui)
            condition_iter.yaw:set_visible(other_show_ui)
            condition_iter.yaw_base:set_visible(other_show_ui)
            condition_jitter:set_visible(other_show_ui)
            condition_iter.desync:set_visible(other_show_ui)

            condition_jitter.offset:set_visible(other_show_ui and condition_jitter:get() ~= "3-way")
            condition_jitter.way_angle:set_visible(is_three_way)

            -- i don't want to create one more slide for a fucking default angle
            -- rename sliderr, why not
            condition_jitter.first_tick:set_visible(is_default_angle or is_custom_angle)
            condition_jitter.first_tick:set_name(is_default_angle and "Angle  " or "1st Yaw tick")

            condition_jitter.tick_delay:set_visible(is_three_way)
            condition_jitter.randomize_tick_order:set_visible(is_three_way)
            
            condition_jitter.second_tick:set_visible(is_custom_angle)
            condition_jitter.third_tick:set_visible(is_custom_angle)
        end
    end,
}

local c_anti_aims = new_class()
    :struct 'utils' {
        good_conditions     = g_arrays.new_vars(CONDITIONS_AMOUNT, false),
        ground_ticks        = 0,
        old_tick_base       = 0,
        old_tick_count      = 0,
        shifted_ticks       = 0,
        is_firing           = false,

        disable_lag_on_shot = function(self, cmd)
            if self.is_firing then
                cmd.send_packet = true
                cmd.no_choke = true
            end

            self.is_firing = cmd.in_attack
        end,

        was_shooting = function(self)
            local weapon = g_globals.local_player:get_player_weapon(false)

            if weapon == nil then
                return false
            end

            local last_shot_time = weapon.m_fLastShotTime
            if last_shot_time == nil or last_shot_time <= 0.0 then
                return false
            end

            local shot_ticks = math.abs(TIME_TO_TICKS(globals.curtime - last_shot_time))
            return shot_ticks > 0 and shot_ticks < 2
        end,

        update_shifted_ticks_count = function(self, cmd)
            local was_shooting = self:was_shooting()

            if self.old_tick_count == cmd.tickcount then
                self.shifted_ticks = self.shifted_ticks + 1
            else
                self.old_tick_count = cmd.tickcount
                self.shifted_ticks = 0
            end

            if not was_shooting and self.shifted_ticks > 0  then
                -- fix broken aa after dt was disabled and you discharged
                if g_vars.anti_aim.misc.forward_fix:get() then
                    g_vars.cheat.body_yaw.enable:override(false)
                end
            end
        end,

        update_defensive_state = function(self)
            local exploit = rage.exploit:get()
            local tickbase  = g_globals.local_player.m_nTickBase
            
            if exploit < 1.0 or globals.choked_commands > 0 then
                self.old_tick_base = tickbase
                return
            end
            
            local diff = tickbase - self.old_tick_base
            self.good_conditions[8] = diff < 0 or diff > 1
            self.old_tick_base = tickbase
        end,

        update_ground_ticks = function(self)
            local flags         = g_globals.local_player.m_fFlags
            if bit.band(flags, 1) == 1 then
                if self.ground_ticks < 3 then
                    self.ground_ticks = self.ground_ticks + 1
                end
            else
                self.ground_ticks = 0
            end
        end,

        -- ghetto memes but it will save my fucking time (@opai)
        update_good_conditions = function(self, cmd)
            local velocity      = g_globals.local_player.m_vecVelocity

            -- global condition is always valid
            self.good_conditions[1] = true

            -- get air conditions
            self.good_conditions[4] = self.ground_ticks < 3

            -- get standing & moving conditions (ground & low velocity, ground & high velocity)
            self.good_conditions[2] = not self.good_conditions[4] and velocity:length2d() < 10
            self.good_conditions[3] = not self.good_conditions[4] and velocity:length2d() > 10
            
            -- get duck conditions (ducking or fake ducking)
            self.good_conditions[5] = cmd.in_duck or g_vars.cheat.misc.fake_duck:get() 

            -- get air-duck conditions (air & duck)
            self.good_conditions[6] = self.good_conditions[4] and self.good_conditions[5]

            -- get slow walk conditions (not ducking and slow walking)
            self.good_conditions[7] = not self.good_conditions[5] and g_vars.cheat.misc.slow_walk:get()

            -- get defensive conditions (tickbase was changed rapidly LOL)
            self:update_defensive_state()
        end,

        -- after we updated all "good" conditions
        -- we can use this func to get current condition index
        -- and save a lot of time while rendering, setting-up anti-aims, etc.
        -- @opai
        get_condition_index = function(self)
            local highest_index = 1

            -- get highest priority to latest aa index that fits
            for i = CONDITIONS_AMOUNT, 2, -1 do
                local condition_vars = g_vars.anti_aim.setup.conditions[i]

                if self.good_conditions[i] and condition_vars.override:get() then
                    if i > highest_index then highest_index = i end
                end
            end

            return highest_index
        end,

        get_ui_value = function(var, overridden)
            return overridden and var:get_override() or var:get()
        end,

        reset_all = function(self)
            self.ground_ticks    = 0
            self.old_tick_base   = 0

            for i = 2, CONDITIONS_AMOUNT do
                self.good_conditions[i] = false
            end
        end,

        run_after_presets = function(self, cmd)
            self:update_shifted_ticks_count(cmd)
        end,

        run = function(self, cmd)
            self:update_ground_ticks()
            self:update_good_conditions(cmd)
        end
    }

    :struct 'manual' {
        reset_yaw_offset    = false,
        manual_angle        = nil,

        angles_on_ticks     = g_arrays.new_vars(3, 0),
        elapsed_ticks       = 0,

        tick_order          = 0,
        tick_random_order   = 0,

        get_manual_angle = function()
            local manual_yaw = g_vars.anti_aim.manual.direction:get()
        
            if manual_yaw_base == "Disabled" then
                return nil
            end
    
            return g_manual_angles[manual_yaw]
        end,

        -- no reason to explain that maybe?
        -- just flip every angle with in-game tick timers (@opai)
        -- a good combination with "Defensive" condition anti aim tho
        get_jitter_3way_angle = function(self, condition, jitter_name, cmd, overridden)
            if jitter_name ~= "3-way" then
                return 0
            end

            local jitter            = condition.yaw_jitter

            local first_tick        = self.utils.get_ui_value(jitter.first_tick, overridden)
            local second_tick       = self.utils.get_ui_value(jitter.second_tick, overridden)
            local third_tick        = self.utils.get_ui_value(jitter.third_tick, overridden)

            if jitter.way_angle:get() == "Default" then
                self.angles_on_ticks[1] = first_tick
                self.angles_on_ticks[2] = -first_tick * 0.5
                self.angles_on_ticks[3] = -first_tick  
            else
                self.angles_on_ticks[1] = first_tick
                self.angles_on_ticks[2] = second_tick
                self.angles_on_ticks[3] = third_tick
            end

            local treshold              = self.utils.get_ui_value(jitter.tick_delay, overridden)
            local randomize             = self.utils.get_ui_value(jitter.randomize_tick_order, overridden)

            if globals.choked_commands == 0 then
                if globals.tickcount - self.elapsed_ticks >= treshold then
                    self.tick_order     = self.tick_order + 1
                    self.elapsed_ticks  = globals.tickcount

                    self.tick_random_order = randomize and utils.random_int(1, 3) or 3
                end

                self.tick_order = self.tick_order % self.tick_random_order
            end

            return self.angles_on_ticks[self.tick_order + 1]
        end,

        manuals_enabled = function(self)
            return self.manual_angle ~= nil
        end,

        reset_all = function(self)
            self.reset_yaw_offset    = false
            self.manual_angle        = nil

            for i = 1, 3 do
                self.angles_on_ticks[i] = 0
            end

            self.elapsed_ticks       = 0

            self.tick_order          = 0
            self.tick_random_order   = 0
        end,

        run = function(self, cmd, condition, overridden)
            -- i want to kys, this is retarted but works in 100% (@opai)
            local freestanding_enabled  = g_vars.anti_aim.misc.freestanding:get()
            local freestanding_options  = g_vars.anti_aim.misc.freestanding.options

            local manuals_enabled       = self:manuals_enabled()
            local manuals_options       = g_vars.anti_aim.manual.direction.options

            local manual_disable_jitter               = manuals_enabled and g_utils.is_in_selectable(manuals_options, 3, "No Jitter")
            local freestanding_disable_jitter         = freestanding_enabled and g_utils.is_in_selectable(freestanding_options, 3, "No Jitter")
            local disable_jitter                      = manual_disable_jitter or freestanding_disable_jitter
            
            local jitter_type                   = self.utils.get_ui_value(condition.yaw_jitter, overridden)
            local three_way_angle               = disable_jitter and 0 or self:get_jitter_3way_angle(condition, jitter_type, cmd, overridden)

            self.manual_angle = self.get_manual_angle()

            if self.manual_angle == nil then
                if three_way_angle == 0 then
                    local current_offset = g_vars.cheat.yaw.offset:get()

                    if not self.reset_yaw_offset then
                        g_vars.cheat.yaw.offset:override(0)

                        self.reset_yaw_offset = true
                    end
                else
                    g_vars.cheat.yaw.offset:override(three_way_angle)

                    self.reset_yaw_offset = false
                end

                return
            end

            g_vars.cheat.yaw.offset:override(self.manual_angle + three_way_angle)

            self.reset_yaw_offset = false
        end
    }

    :struct 'presets' {
        reset_aa_settings   = false,

        -- i don't want to do static values cuz anyway you can watch them and steal to other lua
        -- fuck all dumpers, all values for each user will be unique :D (@opai)
        random_jitter_delta = 0,
        random_3way_delta   = 0,  

        reset_ui_overrides = function()
            g_vars.cheat.pitch:override(nil)
    
            g_vars.cheat.yaw.angle:override(nil)
            g_vars.cheat.yaw.base:override(nil)
            g_vars.cheat.yaw.offset:override(nil)
            g_vars.cheat.yaw.avoid_backstab:override(nil)

            g_vars.cheat.yaw_modifier.type:override(nil)
            g_vars.cheat.yaw_modifier.offset:override(nil)

            g_vars.cheat.body_yaw.enable:override(nil)
            g_vars.cheat.body_yaw.inverter:override(nil)
            g_vars.cheat.body_yaw.left_limit:override(nil)
            g_vars.cheat.body_yaw.right_limit:override(nil)
            g_vars.cheat.body_yaw.options:override(nil)
            g_vars.cheat.body_yaw.lby_mode:override(nil)

            g_vars.cheat.freestanding:override(nil)
        end,

        reset_condition_overrides = function(anti_aim)
            anti_aim.pitch:override(nil)
            anti_aim.yaw:override(nil)
            anti_aim.yaw_base:override(nil)
    
            anti_aim.yaw_jitter:override(nil)
            anti_aim.yaw_jitter.offset:override(nil)
            anti_aim.yaw_jitter.way_angle:override(nil)
            anti_aim.yaw_jitter.first_tick:override(nil)
            anti_aim.yaw_jitter.second_tick:override(nil)
            anti_aim.yaw_jitter.third_tick:override(nil)
            anti_aim.yaw_jitter.tick_delay:override(nil)
            anti_aim.yaw_jitter.randomize_tick_order:override(nil)
    
            anti_aim.desync:override(nil)
            anti_aim.desync.inverter:override(nil)
            anti_aim.desync.left_limit:override(nil)
            anti_aim.desync.right_limit:override(nil)
            anti_aim.desync.options:override(nil)
            anti_aim.desync.lby_mode:override(nil)
        end,

        reset_all = function(self)
            local setup             = g_vars.anti_aim.setup

            self.reset_aa_settings      = false
            self.random_jitter_delta    = 0
            self.random_3way_delta      = 0
            
            self.reset_ui_overrides()

            for i = 1, CONDITIONS_AMOUNT do
                local condition_iter = setup.conditions[i]
                self.reset_condition_overrides(condition_iter)
            end
        end,

        -- finally, start our builder
        override_anti_aims = function(self, condition, overridden)
            local cheat_vars            = g_vars.cheat

            local freestanding_enabled  = g_vars.anti_aim.misc.freestanding:get()
            local freestanding_options  = g_vars.anti_aim.misc.freestanding.options

            local manuals_enabled       = self.manual:manuals_enabled()
            local manuals_options       = g_vars.anti_aim.manual.direction.options

            local desync                = condition.desync

            local manual_disable_jitter             = manuals_enabled and g_utils.is_in_selectable(manuals_options, 3, "No Jitter")
            local manual_disable_jitter_dsy         = manuals_enabled and g_utils.is_in_selectable(manuals_options, 3, "No Body Jitter")
            local manual_disable_at_targets         = manuals_enabled and g_utils.is_in_selectable(manuals_options, 3, "No At-Targets")

            local freestanding_disable_jitter        = freestanding_enabled and g_utils.is_in_selectable(freestanding_options, 3, "No Jitter")
            local freestanding_disable_jitter_dsy    = freestanding_enabled and g_utils.is_in_selectable(freestanding_options, 3, "No Body Jitter")
            local freestanding_disable_at_targets    = freestanding_enabled and g_utils.is_in_selectable(freestanding_options, 3, "No At-Targets")

            local disable_jitter = manual_disable_jitter or freestanding_disable_jitter
            local disable_jitter_dsy = manual_disable_jitter_dsy or freestanding_disable_jitter_dsy
            local disable_at_targets = manual_disable_at_targets or freestanding_disable_at_targets

            -- choose overriden or non overriden configs
            local pitch             = self.utils.get_ui_value(condition.pitch, overridden)
            local yaw               = self.utils.get_ui_value(condition.yaw, overridden)
            local yaw_base          = self.utils.get_ui_value(condition.yaw_base, overridden)

            local jitter            = self.utils.get_ui_value(condition.yaw_jitter, overridden)
            local jitter_offset     = self.utils.get_ui_value(condition.yaw_jitter.offset, overridden)

            local desync_enable     = self.utils.get_ui_value(desync, overridden)

            local desync_inverter   = self.utils.get_ui_value(desync.inverter, overridden)
            local desync_left       = self.utils.get_ui_value(desync.left_limit, overridden)
            local desync_right      = self.utils.get_ui_value(desync.right_limit, overridden)
            local desync_options    = self.utils.get_ui_value(desync.options, overridden)
            local desync_lby        = self.utils.get_ui_value(desync.lby_mode, overridden)

            local jitter_name   = jitter == "3-way" and "Disabled" or jitter

            cheat_vars.pitch:override(pitch)
            
            cheat_vars.yaw.angle:override(yaw)
            cheat_vars.yaw.base:override(disable_at_targets and "Local View" or yaw_base)

            cheat_vars.yaw_modifier.type:override(disable_jitter and "Disabled" or jitter_name)
            cheat_vars.yaw_modifier.offset:override(jitter_offset)
            
            cheat_vars.body_yaw.enable:override(desync_enable)
            cheat_vars.body_yaw.inverter:override(desync_inverter)
            cheat_vars.body_yaw.left_limit:override(desync_left)
            cheat_vars.body_yaw.right_limit:override(desync_right)
            cheat_vars.body_yaw.options:override(disable_jitter_dsy and "-" or desync_options)
            cheat_vars.body_yaw.lby_mode:override(desync_lby)

            self.manual:run(cmd, condition, overridden)
        end,

        -- i can't even imagine unversal code here (will get more effort and abstractions)
        -- so the only way is hard-code current presets (@opai)
        force_prebuilt_presets = function(self)
            local good_conditions   = self.utils.good_conditions
            local conditions        = g_vars.anti_aim.setup.conditions
            local presets           = g_vars.anti_aim.setup.presets:get()
            
            local global_condition      = conditions[1]
            local moving_condition      = conditions[3]
            local air_condition         = conditions[4]
            local duck_condition        = conditions[5]
            local defensive_condition   = conditions[8]

            if presets == "None" then
                self.reset_ui_overrides()
                return
            end

            local random_desync = math.clamp(self.random_jitter_delta, 0, 60)

            if presets == "Charon Baby" then
                -- set global preset
                global_condition.pitch:override("Down")
                global_condition.yaw:override("Backward")
                global_condition.yaw_base:override("At targets")
                global_condition.yaw_jitter:override("Center")
                global_condition.yaw_jitter.offset:override(-self.random_jitter_delta)

                global_condition.desync:override(true)
                global_condition.desync.left_limit:override(random_desync)
                global_condition.desync.right_limit:override(random_desync)
                global_condition.desync.options:override("Jitter")
                global_condition.desync.lby_mode:override("Opposite")

                -- set moving preset
                moving_condition.pitch:override("Down")
                moving_condition.yaw:override("Backward")
                moving_condition.yaw_base:override("At targets")
                moving_condition.yaw_jitter:override("Center")
                moving_condition.yaw_jitter.offset:override(-62)

                moving_condition.yaw_jitter.way_angle:override("Default")
                moving_condition.yaw_jitter.first_tick:override(-self.random_3way_delta)
                moving_condition.yaw_jitter.tick_delay:override(2)
                moving_condition.yaw_jitter.randomize_tick_order:override(true)

                moving_condition.desync:override(true)
                moving_condition.desync.left_limit:override(random_desync)
                moving_condition.desync.right_limit:override(random_desync)
                moving_condition.desync.options:override("Jitter")
                moving_condition.desync.lby_mode:override("Opposite")

                -- set air preset
                air_condition.pitch:override("Down")
                air_condition.yaw:override("Backward")
                air_condition.yaw_base:override("At targets")
                air_condition.yaw_jitter:override("3-way")
                air_condition.yaw_jitter.offset:override(-self.random_jitter_delta)

                air_condition.yaw_jitter.way_angle:override("Default")
                air_condition.yaw_jitter.first_tick:override(math.clamp(-self.random_3way_delta + 15, -50, 70))
                air_condition.yaw_jitter.tick_delay:override(2)
                air_condition.yaw_jitter.randomize_tick_order:override(false)

                air_condition.desync:override(true)
                air_condition.desync.left_limit:override(60)
                air_condition.desync.right_limit:override(60)
                air_condition.desync.options:override("Jitter")
                air_condition.desync.lby_mode:override("Opposite")

                -- set defensive preset
                defensive_condition.pitch:override("Fake up")
                defensive_condition.yaw:override("Backward")
                defensive_condition.yaw_base:override("At targets")
                defensive_condition.yaw_jitter:override("3-way")
                defensive_condition.yaw_jitter.offset:override(-self.random_jitter_delta)

                defensive_condition.yaw_jitter.way_angle:override("Default")
                defensive_condition.yaw_jitter.first_tick:override(self.random_3way_delta)
                defensive_condition.yaw_jitter.tick_delay:override(1)
                defensive_condition.yaw_jitter.randomize_tick_order:override(true)

                defensive_condition.desync:override(false)

                -- now select presets on condition 
                if good_conditions[8] then
                    self:override_anti_aims(defensive_condition, true)
                elseif good_conditions[4] then
                    self:override_anti_aims(air_condition, true)
                elseif not good_conditions[7] and not good_conditions[5] and good_conditions[3] then
                    self:override_anti_aims(moving_condition, true)
                else
                    self:override_anti_aims(global_condition, true)
                end
            elseif presets == "Charon Plus" then
                -- set global preset
                global_condition.pitch:override("Down")
                global_condition.yaw:override("Backward")
                global_condition.yaw_base:override("At targets")
                global_condition.yaw_jitter:override(globals.choked_commands < 4 and "3-way" or "Center")
                global_condition.yaw_jitter.offset:override(-self.random_jitter_delta)

                global_condition.yaw_jitter.way_angle:override("Default")
                global_condition.yaw_jitter.first_tick:override(-self.random_3way_delta)
                global_condition.yaw_jitter.tick_delay:override(3)
                global_condition.yaw_jitter.randomize_tick_order:override(true)

                global_condition.desync:override(true)
                global_condition.desync.left_limit:override(60)
                global_condition.desync.right_limit:override(60)
                global_condition.desync.options:override("Jitter")
                global_condition.desync.lby_mode:override("Disabled")

                -- set duck preset
                duck_condition.pitch:override("Down")
                duck_condition.yaw:override("Backward")
                duck_condition.yaw_base:override("At targets")
                duck_condition.yaw_jitter:override("Disabled")
                duck_condition.yaw_jitter.offset:override(-self.random_jitter_delta)

                duck_condition.desync:override(true)
                duck_condition.desync.inverter:override(false)
                duck_condition.desync.left_limit:override(60)
                duck_condition.desync.right_limit:override(60)
                duck_condition.desync.options:override("-")
                duck_condition.desync.lby_mode:override("Opposite")

                -- set defensive preset
                defensive_condition.pitch:override("Fake up")
                defensive_condition.yaw:override("Backward")
                defensive_condition.yaw_base:override("At targets")
                defensive_condition.yaw_jitter:override("3-way")
                defensive_condition.yaw_jitter.offset:override(-self.random_jitter_delta)

                defensive_condition.yaw_jitter.way_angle:override("Default")
                defensive_condition.yaw_jitter.first_tick:override(self.random_3way_delta)
                defensive_condition.yaw_jitter.tick_delay:override(1)
                defensive_condition.yaw_jitter.randomize_tick_order:override(true)

                defensive_condition.desync:override(false)

                -- now select presets on condition 
                if good_conditions[8] then
                    self:override_anti_aims(defensive_condition, true)
                elseif not good_conditions[4] and good_conditions[5] then
                    self:override_anti_aims(duck_condition, true)
                else
                    self:override_anti_aims(global_condition, true)
                end
            end
        end,
        
        update_random_values = function(self)
            -- between these values anti-aims are going to be unhittable :W
            self.random_jitter_delta    = utils.random_int(utils.random_int(1, 2) == 2 and 50 or 79, utils.random_int(1, 2) == 2 and 90 or 81)
            self.random_3way_delta      = utils.random_int(30, 36)
        end,

        run = function(self, cmd)
            utils.random_seed(globals.tickcount)
            
            -- force anti-backstab
            g_vars.cheat.yaw.avoid_backstab:override(true)
            g_vars.cheat.freestanding:override(g_vars.anti_aim.misc.freestanding:get())

            local presets   = g_vars.anti_aim.setup.presets:get()
            if presets ~= "Custom" then
                if not self.reset_aa_settings then
                    self:reset_all()
                    self:update_random_values()
                    self.reset_aa_settings = true
                end

                self:force_prebuilt_presets()

                return
            end

            if self.reset_aa_settings then
                local setup             = g_vars.anti_aim.setup

                for i = 1, CONDITIONS_AMOUNT do
                    local condition_iter = setup.conditions[i]
                    self.reset_condition_overrides(condition_iter)
                end
            end

            self.reset_aa_settings      = false
            self.random_jitter_delta    = 0

            local index                 = self.utils:get_condition_index()
            local condition             = g_vars.anti_aim.setup.conditions[index]
            self:override_anti_aims(condition)
        end,
    }

    :struct 'g' {
        start_reset = false,

        -- reset all info after death \ map connect
        reset_info = function(self)
            if not self.start_reset then
                
                self.utils:reset_all()
                self.manual:reset_all()
                self.presets:reset_all()

                self.start_reset = true
            end
        end,

        run = function(self, cmd)
            if not g_vars.anti_aim.main.enable:get() or g_globals.local_player == nil then
                return
            end
            
            self.utils:run(cmd)
            self.presets:run(cmd)
            self.utils:run_after_presets(cmd)
        end,

        reset_all = function(self)
            self.presets:reset_all()
        end,
    }

local c_ragebot_tweaks = new_class()
    :struct 'utils' {
        in_air_origin = nil,

        get_weapon = function(self, ent)
            csweapon = ent:get_player_weapon():get_weapon_info().weapon_name
            weapon = ''
            if csweapon == "weapon_scar20" or "weapon_g3sg1" then
                weapon = "Auto"
            end
            if csweapon == "weapon_ssg08" then
                weapon = "Scout"
            end
            if csweapon == "weapon_awp" then
                weapon = "AWP"
            end
            if csweapon == "weapon_taser" then
                weapon = "Taser"
            end
            if csweapon == "weapon_knife" then
                weapon = "Knife"
            end
            return weapon
        end,

        predict_eyepos = function(self, ent) 
           -- deleted due to it's not public code and did not by @opai
        end,

        update_in_air_origin = function(self) 
            self.in_air_origin = g_globals.local_player:get_origin().z
        end,
    }

    :struct 'g' {
        predicted_pos = vector(),

        break_lc_in_air = function(self)    
            if g_vars.ragebot.main.break_lc_in_air:get() then
                g_vars.cheat.dt_mode:override(c_anti_aims.utils.ground_ticks == 0 and "Always on" or "On peek")
            else
                if g_vars.cheat.dt_mode:get_override() ~= nil then
                    g_vars.cheat.dt_mode:override(nil)
                end
            end
        end,

        -- credits @rod9
        auto_discharge = function(self)                                                    
            if g_vars.cheat.peek_assist:get() or not g_vars.cheat.dt:get() then return end

            if g_vars.ragebot.main.teleport_in_air:get() then 
                if c_anti_aims.utils.ground_ticks > 2 then -- if onground then off
                    return
                end

                local exploit = rage.exploit:get()

                -- don't disable discharged dt lol
                if exploit < 1.0 then
                    return
                end

                -- thanks @AkatsukiSun for idea 
                if g_vars.ragebot.main.teleport_in_air.only_on_land:get() then
                   -- deleted due to it's not public code and did not by @opai
                else
                    -- deleted due to it's not public code and did not by @opai
                end

                if g_utils.is_in_selectable(g_vars.ragebot.main.teleport_in_air.options, 5, self.utils:get_weapon(g_globals.local_player)) then
                    entity.get_players(true, false, function(enemy)
                      -- deleted due to it's not public code and did not by @opai
                    end)    
                end 
            end 
        end,
        
        run = function(self) 
            c_anti_aims.utils:update_ground_ticks()
            self:break_lc_in_air()
            self:auto_discharge()
        end
    }


-- fucking hate this, have a lot of shit code and logic
-- but works good (@opai)
local c_visuals = new_class()
    :struct 'utils' {
        fix_chams_override = function()
            if g_vars.cheat.chams.model_enable:get_override() ~= nil then
                g_vars.cheat.chams.model_enable:override(nil)
            end

            if g_vars.cheat.chams.model_color:get_override() ~= nil then
                g_vars.cheat.chams.model_color:override(nil)
            end

            if g_vars.cheat.chams.weapon_enable:get_override() ~= nil then
                g_vars.cheat.chams.weapon_enable:override(nil)
            end

            if g_vars.cheat.chams.weapon_color:get_override() ~= nil then
                g_vars.cheat.chams.weapon_color:override(nil)
            end

            if g_vars.cheat.chams.viewmodel_enable:get_override() ~= nil then
                g_vars.cheat.chams.viewmodel_enable:override(nil)
            end
            
            if g_vars.cheat.chams.viewmodel_color:get_override() ~= nil then
                g_vars.cheat.chams.viewmodel_color:override(nil)
            end
        end
    }

    :struct 'animation' {
        is_finite = function(value)
            return value ~= math.huge or value ~= -math.huge
        end,
        
        lerp = function(self, a, b, t)
            if not self:is_finite(a) and not self:is_finite(b) then
                return 0
            end
        
            if t == 0 then return a
            elseif t == 1 then return b
            elseif self:is_finite(t) and a == b then return a end
            
            return a + t * (b - a)
        end,

        update = function(self, val, modifier, condition)
            local lerp_to = condition and 1 or 0
            local lerp_amount = modifier == nil and 1 or modifier
            val = self:lerp(val, lerp_to, globals.frametime * 30 * lerp_amount)
        
            if val >= 1 then val = 1
            elseif val <= 0 then val = 0 end
            return val
        end,
    }

    :struct 'screen' {
        screen_size         = vector(-1, -1),

        update = function(self)
            self.screen_size = render.screen_size()
        end,
    }

    :struct 'camera' {
        viewmodel_aim_angles    = nil,
        viewmodel_aim_time      = 0.0,

        reset_viewmodel_offset  = true,
        reset_aspect_ratio      = false,

        run = function(self, ctx)
            local camera = g_vars.misc.camera

            if camera.aspect_ratio:get() then
                cvar.r_aspectratio:float(camera.aspect_ratio.amount:get() / 100)
                
                self.reset_aspect_ratio = false
            else
                if not self.reset_aspect_ratio then
                    cvar.r_aspectratio:float(0.0)
                    self.reset_aspect_ratio  = true
                end
            end

            if camera.custom_fov:get() then
                CHEAT_FOV:override(camera.custom_fov.amount:get())
            else
                if CHEAT_FOV:get_override() ~= nil then
                    CHEAT_FOV:override(nil)
                end
            end

            -- grab viewmodel & adjust their pos & angles (@opai)
            local custom_viewmodel = camera.custom_viewmodel
            if custom_viewmodel:get() and g_globals.local_player ~= nil and g_globals.local_player:is_alive() then
                local viewmodel_handle = g_globals.local_player.m_hViewModel
                if viewmodel_handle ~= nil and viewmodel_handle ~= 0 then
                    local handle = viewmodel_handle[0][0]
                    local viewmodel_abs_angles = g_vfuncs.get_abs_angles(handle)
                    local viewmodel_abs_origin = g_vfuncs.get_abs_origin(handle)

                    -- adjust angles
                    viewmodel_abs_angles.x = viewmodel_abs_angles.x + custom_viewmodel.pitch:get()
                    viewmodel_abs_angles.y = viewmodel_abs_angles.y + custom_viewmodel.yaw:get()
                    viewmodel_abs_angles.z = viewmodel_abs_angles.z + custom_viewmodel.roll:get()

                    if custom_viewmodel.aim_at_enemy:get() and self.viewmodel_aim_angles ~= nil then
                        local diff = globals.realtime - self.viewmodel_aim_time 
                        if diff < 0.5 then 
                            viewmodel_abs_angles.x = self.viewmodel_aim_angles.x
                            viewmodel_abs_angles.y = self.viewmodel_aim_angles.y
                            viewmodel_abs_angles.z = self.viewmodel_aim_angles.z    
                        else
                            self.viewmodel_aim_angles   = nil
                            self.viewmodel_aim_time     = 0.0
                        end
                    end

                    g_vfuncs.set_abs_angles(handle, viewmodel_abs_angles)

                    cvar.viewmodel_fov:int(g_cached_viewmodel_fov + custom_viewmodel.amount:get(), true)
                    cvar.viewmodel_offset_x:int(g_cached_viewmodel_values.x + custom_viewmodel.x:get(), true)
                    cvar.viewmodel_offset_y:int(g_cached_viewmodel_values.y + custom_viewmodel.y:get(), true)
                    cvar.viewmodel_offset_z:int(g_cached_viewmodel_values.z + custom_viewmodel.z:get(), true)
                end

                self.reset_viewmodel_offset = false
            else
                if not self.reset_viewmodel_offset then
                    cvar.viewmodel_fov:int(g_cached_viewmodel_fov, true)

                    cvar.viewmodel_offset_x:int(g_cached_viewmodel_values.x, true)
                    cvar.viewmodel_offset_y:int(g_cached_viewmodel_values.y, true)
                    cvar.viewmodel_offset_z:int(g_cached_viewmodel_values.z, true)

                    self.reset_viewmodel_offset = true
                end
            end
        end,
    }

    :struct 'ui' {
        slowdown_lerp = 0.0,

        bind_toggled = function(self, name)
            for _, v in ipairs(ui.get_binds()) do
                if v ~= nil and v.name == name and v.active then
                    return true
                end
            end

            return false
        end,

        toggled_draggables = function()
            if ui.get_alpha() ~= 1 then
                return false
            end

            -- disable mouse input when we gonna drag our ui element
            local mouse_pos = ui.get_mouse_position()
            for _, ptr in pairs(g_drag_n_drops) do
                if ptr.dragger:is_in_area(mouse_pos) then
                    return true
                end
            end

            return false
        end,

        register_dragger = function(ptr, var, size, name, callback)
            var.x:set_visible(false)
            var.y:set_visible(false)

            ptr.dragger     = drag_system.register({var.x, var.y}, size, name, function(self)
                callback(self)
            end)
        end,

        update_dragger = function(self, ptr, mouse_pos)
            local ui_opened = ui.get_alpha() == 1
            local is_in_area = ptr.dragger:is_in_area(mouse_pos)

            ptr.border_alpha = self.animation:update(ptr.border_alpha, 0.3, ui_opened and is_in_area or ptr.dragger.is_dragging)
            ptr.dragger:update()
        end,

        init_indicators = function(self)
            g_drag_n_drops.watermark    = drag_data_t.new()
            g_drag_n_drops.slowdown     = drag_data_t.new()

            -- register watermark
            self.register_dragger(g_drag_n_drops.watermark, g_vars.misc.ui.watermark, vector(120, 120), "Watermark", function(s)
                local ptr = g_drag_n_drops.watermark
                if not g_vars.misc.ui.watermark.enable:get() then
                    return
                end

                render.texture(g_globals.watermark, vector(s.position.x, s.position.y), 
                    vector(s.size.x, s.size.y), color(255, 255, 255, 255), "fr")

                render.rect_outline(vector(s.position.x, s.position.y), vector(s.position.x + s.size.x, s.position.y + s.size.y), 
                    color(255, 255, 255, 255 * ptr.border_alpha), 2 * ptr.border_alpha, 10 * ptr.border_alpha)
            end)

            -- register slowdown
            self.register_dragger(g_drag_n_drops.slowdown, g_vars.misc.ui.slowdown, vector(120, 110), "Slowdown", function(s)
                local ptr = g_drag_n_drops.slowdown

                local valid_local = g_globals.local_player and g_globals.local_player:is_alive()

                local slowdown          = g_vars.misc.ui.slowdown
                local velocity_modifier = valid_local and g_globals.local_player.m_flVelocityModifier or 1.0
                local show_slowdown     = valid_local and slowdown.enable:get() and velocity_modifier < 1.0
                
                self.slowdown_lerp = self.animation:update(self.slowdown_lerp, 0.3, show_slowdown or ui.get_alpha() == 1)
                if self.slowdown_lerp <= 0.0 then
                    return
                end

                local tex_size = vector(75, 38)
                render.texture(g_globals.charon_slowdown, vector(s.position.x + 18, s.position.y + 10), 
                    tex_size, color(255, 255, 255, 255 * self.slowdown_lerp), "fr")

                local accent_color = slowdown.enable.color:get()
                local animated_color = accent_color:alpha_modulate(accent_color.a * self.slowdown_lerp)

                local bar_size          = vector(60, 5)
                local pos_center        = vector(s.position.x + s.size.x / 2, s.position.y + s.size.y / 2 + 10)

                local gradient_text = gradient.text("SLOWDOWN:  " .. math.floor(velocity_modifier * 100) .. "%", false, {
                    animated_color,
                    color(255, 255, 255, 255 * self.slowdown_lerp)
                })

                render.text(2, vector(pos_center.x, pos_center.y - bar_size.y - 5), color(255, 255, 255, 255 * self.slowdown_lerp), "c", gradient_text)

                local base_bar_pos_min = vector(s.position.x + bar_size.x / 2 - 3, pos_center.y)
                local base_bar_pos_max = vector(base_bar_pos_min.x + bar_size.x + 5, pos_center.y + bar_size.y)

                -- ....
                render.shadow(base_bar_pos_min, base_bar_pos_max, animated_color)
                render.rect(base_bar_pos_min, base_bar_pos_max, color(30, 30, 30, 255 * self.slowdown_lerp))
                render.gradient(base_bar_pos_min, vector(base_bar_pos_min.x + bar_size.x * velocity_modifier + 5, base_bar_pos_max.y), 
                                color(255, 255, 255, 255 * self.slowdown_lerp), 
                                animated_color, 
                                color(255, 255, 255, 255 * self.slowdown_lerp), 
                                animated_color, 1)
                                
                render.rect_outline(base_bar_pos_min, base_bar_pos_max, color(30, 30, 30, 150 * self.slowdown_lerp), 1, 1)
                
                render.rect_outline(vector(s.position.x, s.position.y), vector(s.position.x + s.size.x, s.position.y + s.size.y), 
                    color(255, 255, 255, 255 * ptr.border_alpha), 2 * ptr.border_alpha, 10 * ptr.border_alpha)
            end)
        end,

        init = function(self)
            self:init_indicators()
        end,

        update = function(self)
            local mouse_position = ui.get_mouse_position()
            
            self:update_dragger(g_drag_n_drops.watermark, mouse_position)
            self:update_dragger(g_drag_n_drops.slowdown, mouse_position)
        end,
    }

    :struct "crosshair" {
        scope_lerp          = 0.0,
        should_reset_list   = false,
        indicator_list      = {},
        animations          = {},

        add_to_list = function(self, condition, disabled, clr, inactive_clr, text)
            table.insert(self.indicator_list, {
                valid           = condition,
                inactive        = disabled,
                color           = clr,
                inactive_color  = inactive_clr,
                string          = text,
            })
        end,

        get_current_antiaim_condition = function(self)
            local highest_index = 1

            -- get highest priority to latest aa index that fits
            for i = CONDITIONS_AMOUNT - 1, 2, -1 do
                if c_anti_aims.utils.good_conditions[i] then
                    if i > highest_index then highest_index = i end
                end
            end

            return string.upper(g_condition_names[highest_index])
        end,

        run = function(self)
            self.indicator_list  = {}
            if not g_globals.local_player or not g_globals.local_player:is_alive() then
                return
            end

            local crosshair             = g_vars.misc.ui.crosshair
            local crosshair_enable      = crosshair.enable
            local crosshair_indications = crosshair.enable.other_elements
            local accent_color          = crosshair_enable.color:get()
            local second_color          = crosshair_enable.second_color:get()

            if not crosshair.enable:get() then
                return
            end

            -- prepare indicators before rendering
            local exploit = rage.exploit:get()
            local current_condition = self:get_current_antiaim_condition()

            -- INDICATOR STRUCT:
            -- valid          - when indicator should be enabled
            -- inactive       - when state of func in indicator is disabled
            -- color          - active color
            -- inactive_color - disabled indicator color
            -- string         - indicator name

            -- aa data

            local condition_enabled = g_utils.is_in_selectable(crosshair_indications, 3, "Condition")
            local white_color       = color(255, 255, 255)
            self:add_to_list(condition_enabled, false, second_color, nil, self:get_current_antiaim_condition())

            -- exploits
            self:add_to_list(g_vars.cheat.dt:get(), exploit <= 0.0, second_color, color(250, 90, 90), "DT")
            self:add_to_list(g_vars.cheat.hs:get(), false, second_color, nil, "HS")

            -- rage safe data
            self:add_to_list(self.ui:bind_toggled("Body Aim"), false, second_color, nil, "BAIM")
            self:add_to_list(self.ui:bind_toggled("Safe Points"), false, second_color, nil, "SP")

            -- rage data
            self:add_to_list(g_utils.is_in_selectable(crosshair_indications, 3, "Hitchance"), false, color(255, 255, 255), nil, "HC: " .. g_vars.cheat.rage.hitchance:get())
            self:add_to_list(g_utils.is_in_selectable(crosshair_indications, 3, "Damage"), false, color(255, 255, 255), nil, "DMG: " .. g_vars.cheat.rage.mindamage:get())

            local change_crosshair_pos  = crosshair_enable.adjust_pos:get() and g_globals.local_player.m_bIsScoped
            self.scope_lerp             = self.animation:update(self.scope_lerp, 0.35, change_crosshair_pos)

            local indicator_align       = change_crosshair_pos and nil or "c"

            local crosshair_offset      = vector(30 * self.scope_lerp + 3, crosshair_enable.offset:get() + 25, 0);
            local screen_center         = vector((self.screen.screen_size.x / 2) + crosshair_offset.x, (self.screen.screen_size.y / 2) + crosshair_offset.y, 0)

            -- logo of our BEST LUA
            local logo_length = render.measure_text(2, nil, "CHARON.LUA")
            local gradient_animation = gradient.text_animate("CHARON.LUA", 1, 
            {
                color(255, 255, 255), 
                accent_color
            })
            
            gradient_animation:animate()

            render.shadow(vector(screen_center.x - logo_length.x / 2, screen_center.y), 
                            vector(screen_center.x + logo_length.x / 2, screen_center.y), 
                            accent_color)   

            render.text(2, vector(screen_center.x, screen_center.y), color(255, 255, 255, 255), "c", gradient_animation:get_animated_text())

            local list_offset = 0
            for _, indicator in pairs(self.indicator_list) do
                -- update anims
                if self.animations[_] == nil then
                    self.animations[_] = 0.0
                end

                self.animations[_] = self.animation:update(self.animations[_], 0.35, indicator.valid)

                if self.animations[_] > 0.1 then
                    local indicator_color = nil
                    if indicator.inactive and indicator.inactive_color ~= nil then
                        indicator_color = indicator.inactive_color
                    else
                        indicator_color = indicator.color
                    end
        
                    local animated_color    = indicator_color:alpha_modulate(indicator_color.a * self.animations[_])
                    local text_length       = render.measure_text(2, nil, indicator.string)

                    -- to animate this shit to right side of scope line
                    -- calc text center manually & animate it (@opai)
                    local scope_offset  = (logo_length.x / 2) * self.scope_lerp
                    local text_offset   = (text_length.x / 2) * (1.0 - self.scope_lerp)

                    -- total offset with animations
                    local text_center   = screen_center.x - text_offset - scope_offset

                    render.text(2, vector(text_center, screen_center.y + 5 + list_offset), animated_color, nil, indicator.string)

                    list_offset = list_offset + 11 * self.animations[_]
                end
            end
        end,
    }

    :struct "scope" {
        lerp = 0.0,
        
        run = function(self) 
            if not g_globals.local_player then return end

            local screen_center         = vector(self.screen.screen_size.x / 2, self.screen.screen_size.y / 2)

            local ui_scope              = g_vars.misc.ui.scope

            local accent_color          = ui_scope.enable.color:get()
            local second_accent_color   = ui_scope.enable.invert_color:get()
            local size                  = ui_scope.enable.size:get()
            local gap                   = ui_scope.enable.gap:get()

            local draw_scope = g_globals.local_player.m_bIsScoped and ui_scope.enable:get()
            g_vars.cheat.world.override_zoom_overlay:override(draw_scope and "Remove All" or nil)

            self.lerp = self.animation:update(self.lerp, 0.35, draw_scope)

            if self.lerp > 0.1 then
                local animated_color = accent_color:alpha_modulate(accent_color.a * self.lerp)
                local second_animated_color = second_accent_color:alpha_modulate(second_accent_color.a * self.lerp)

                render.text(2, vector(screen_center.x, screen_center.y), animated_color, "c", "*")
                render.gradient(vector(screen_center.x + gap, screen_center.y), vector(screen_center.x + size + gap, screen_center.y + 1), animated_color, second_animated_color, animated_color, second_animated_color)
                render.gradient(vector(screen_center.x - gap, screen_center.y), vector(screen_center.x - size - gap, screen_center.y + 1), animated_color, second_animated_color, animated_color, second_animated_color)
                render.gradient(vector(screen_center.x, screen_center.y + gap), vector(screen_center.x + 2, screen_center.y + size + gap), animated_color, second_animated_color, second_animated_color, second_animated_color)
                render.gradient(vector(screen_center.x, screen_center.y - gap), vector(screen_center.x + 2, screen_center.y - size - gap), animated_color, second_animated_color, second_animated_color, second_animated_color)
            end
        end,
    }

    -- this is the best feature in this lua 
    :struct 'smoke' {
        smoke_gif_lerp      = 0.0,
        background_lerp     = 0.0,
        angle_lerp          = 0.0,

        change_fov = function(self, ctx)
            if g_globals.smoke_data.end_smoke then
                local session_duration  = globals.realtime - g_globals.smoke_data.end_smoke_time
                local strength          = g_globals.smoke_data.end_smoke_strength

                local end_duration      = 9 * strength
                local off_duration      = 15 * strength

                local fov_changing      = session_duration > 0 and session_duration <= end_duration

                if session_duration >= off_duration then
                    g_globals.smoke_data.end_smoke          = false
                    g_globals.smoke_data.end_smoke_time     = 0
                    g_globals.smoke_data.end_smoke_strength  = 0.0

                    self.utils:fix_chams_override()
                    return
                end
            
                self.angle_lerp     = self.animation:update(self.angle_lerp, 0.05, fov_changing)

                -- big thanks to my friend, @INFIRMS, for this code lol
                local angles = vector(ctx.view.x + g_utils.create_clamped_sine(1, 180 * strength, 90 * strength, globals.realtime) * self.angle_lerp, 
                                ctx.view.y + g_utils.create_clamped_sine(1, 180 * strength, 90 * strength, globals.realtime) * self.angle_lerp, 
                                ctx.view.z + g_utils.create_clamped_sine(1, 180 * strength, 90 * strength, globals.realtime) * self.angle_lerp)

                ctx.fov     = ctx.fov + g_utils.create_clamped_sine(1, 120 * strength, 60 * strength, globals.realtime) * self.angle_lerp
                ctx.view    = angles

                local color_alpha   = math.clamp(math.abs(g_utils.create_clamped_sine(1, 2, 0.3, globals.realtime) * self.angle_lerp), 0, 1)
                local alpha         = math.clamp(math.abs(g_utils.create_clamped_sine(1, 1, 0.3, globals.realtime) * self.angle_lerp), 0, 1)
                local hide_color    = fov_changing and color(255 * color_alpha, 255 * (1.0 - color_alpha), 255 - 255 * (1.0 - color_alpha), 255 * alpha) or nil

                g_vars.cheat.chams.model_enable:override(fov_changing)
                g_vars.cheat.chams.model_color:override(hide_color)
            end
        end,
        
        run = function(self)
            if g_globals.local_player and g_globals.local_player:is_alive() and g_globals.smoke_data.end_smoke then
                local alpha         = math.clamp(math.abs(g_utils.create_clamped_sine(1, 1, 0.3, globals.realtime) * self.angle_lerp), 0, 1)
                render.rect(vector(0, 0), self.screen.screen_size, color(10, 10 * alpha, 10 * (1.0 - alpha), 200 * alpha))

                -- local size = vector(1000 * alpha, 1000 * alpha)
                -- local center = vector(self.screen.screen_size.x / 2, self.screen.screen_size.y / 2)

                -- render.texture(g_globals.CMePt6, vector(center.x - size.x / 2, center.y - size.y / 2),
                --     size, color(255, 255, 255, 255 * alpha), "fr")
            end

            if g_globals.smoke_data.start_smoke then
                local session_duration  = globals.realtime - g_globals.smoke_data.smoke_time
                local smoke_playing     = session_duration >= 2 and session_duration <= 8
                local bg_playing        = session_duration <= 9

                if session_duration >= 10 then
                    g_globals.smoke_data.start_smoke    = false
                    g_globals.smoke_data.smoke_time     = 0

                    if not g_globals.smoke_data.end_smoke then
                        g_globals.smoke_data.end_smoke      = true
                        g_globals.smoke_data.end_smoke_time = globals.realtime

                        g_globals.smoke_data.end_smoke_strength = (g_vars.home.smoke.nicotine_amount:get() / 80)
                    end

                    self.utils:fix_chams_override()
                end

                self.smoke_gif_lerp     = self.animation:update(self.smoke_gif_lerp, 0.2, smoke_playing)
                self.background_lerp    = self.animation:update(self.background_lerp, 0.2, bg_playing)

                render.rect(vector(0, 0), self.screen.screen_size, color(10, 10, 10, 200 * self.background_lerp))
                render.texture(g_globals.smoke_gif, vector(-10, -10), self.screen.screen_size + vector(20, 20), color(255, 255, 255, 255 * self.smoke_gif_lerp), "fr")

                if smoke_playing and self.smoke_gif_lerp > 0.1 and self.smoke_gif_lerp < 0.2 then
                    g_winapi.play_sound(CHARON_PATH .. "\\best.wav")
                end

                local hide_color = bg_playing and color(0, 0, 0, 255 * (1.0 - self.background_lerp)) or nil

                g_vars.cheat.chams.weapon_enable:override(bg_playing)
                g_vars.cheat.chams.weapon_color:override(hide_color)

                g_vars.cheat.chams.viewmodel_enable:override(bg_playing)
                g_vars.cheat.chams.viewmodel_color:override(hide_color)

                -- hide hud & viewmodel for better effect
                cvar.cl_drawhud:int(bg_playing and 0 or 1, true)
            end
        end,
    }

    :struct 'g' {
        reset_info = function(self)
            g_globals.smoke_data.start_smoke    = false
            g_globals.smoke_data.smoke_time     = 0

            g_globals.smoke_data.end_smoke          = false
            g_globals.smoke_data.end_smoke_time     = 0

        end,

        reset_all = function(self)
            self.utils:fix_chams_override()

            g_vars.cheat.world.override_zoom_overlay:override(nil)

            cvar.r_aspectratio:float(0.0)
            cvar.viewmodel_fov:int(g_cached_viewmodel_fov, true)
            cvar.viewmodel_offset_x:int(g_cached_viewmodel_values.x, true)
            cvar.viewmodel_offset_y:int(g_cached_viewmodel_values.y, true)
            cvar.viewmodel_offset_z:int(g_cached_viewmodel_values.z, true)
        end,

        run = function(self)
            self.screen:update()
            self.ui:update()
            self.crosshair:run()
            self.smoke:run()
            self.scope:run()
        end
    }

local c_misc = new_class() 
    :struct "utils" {
        undercover_first_list = { -- 107
           -- deleted due to it's not public code and did not by @opai
        },

        undercover_second_list = { -- 45
           -- deleted due to it's not public code and did not by @opai
        },

        iq_symbols = { -- 67
           -- deleted due to it's not public code and did not by @opai
        },

        hitgroup_str = {
            [0] = 'generic',
            'head', 'chest', 'stomach',
            'left arm', 'right arm',
            'left leg', 'right leg',
            'neck', 'generic', 'gear'
        },
    }

    :struct "g" {
        undercover = "",
        generate_undercover = function(self) 
           -- deleted due to it's not public code and did not by @opai
        end,

        hitlog = function(self, shot)
               -- deleted due to it's not public code and did not by @opai
        end,

        run = function(self) 
            -- g_vars.misc.undercover.value:set_visible(g_vars.misc.undercover.enable:get())
            -- g_vars.misc.undercover.generate:set_visible(g_vars.misc.undercover.enable:get())
            -- g_vars.misc.undercover.enable.symbols:set_visible(g_vars.misc.undercover.enable:get())
        end
    }
-- [[ ************************** LUA FEATURES END ************************** ]] --

-- [[ ************************** LUA HOOKS ************************** ]] --
local g_vmt_hook = {}
g_vmt_hook.init = function(ptr)
    local info = {}
    info.vmt = hook.new(ptr)
    info.originals = {}

    info.hook_func = function(cast, func, index)
        info.originals[index] = info.vmt.hook(cast, func, index)
    end

    info.get_original = function(index)
        return info.originals[index]
    end

    info.unhook = function(index)
        info.vmt.unhook(index)
    end

    info.unhook_all = function(index)
        info.vmt.unhook_all()
    end

    return info
end

local g_hooks = {}
g_hooks = {
    player  = nil,
    panel   = nil,
    surface = nil,
}

local g_panels = {}
g_panels = {
    focus_overlay_panel = 0,
    game_console        = 0,
    competition_list    = 0,
    serverbrowser       = 0,
}

get_panel = function(current_panel, panel, panel_name)
    if current_panel == 0 then
        local name = ffi.string(g_vfuncs.get_panel_name(panel))

        if name == panel_name then
            current_panel = panel
        end
    end

    return current_panel
end

local vgui_materials = {"vgui_white", "vgui/hud/800corner1", "vgui/hud/800corner2", "vgui/hud/800corner3", "vgui/hud/800corner4"}

is_console = false
is_serverbrowser = false

local g_hooked = {}
g_hooked = {
    update_clientside_animation = function(ecx, edx)
        local original = g_hooks.player.get_original(224)
    
        if ecx == nil or g_vfuncs.get_client_entity == nil or g_globals.local_player == nil then
            original(ecx, edx)
            return
        end

        local index = g_globals.local_player:get_index()
        local ptr = g_vfuncs.get_client_entity(index)

        if ptr == nil or ptr == 0 or ptr ~= ecx or not g_globals.local_player:is_alive() then
            original(ecx, edx)
            return
        end

        original(ecx, edx)

        local m_CachedBoneData_Offset   = ffi.cast("unsigned int", ptr) + 0x2914
        local m_CachedBoneData          = ffi.cast("bone_cache_t*", m_CachedBoneData_Offset)

        local animstate                 = g_globals.local_player:get_anim_state()
        local move_overlay              = g_globals.local_player:get_anim_overlay(6)
        
        -- too old paste from ayala (2018)
        -- credits to Filatov lol
        local step = math.pi * 2.0 / 300
        
        g_globals.anims_data.bone_rotation = g_globals.anims_data.bone_rotation + step

        if g_globals.anims_data.bone_rotation > math.pi * 2.0 then
            g_globals.anims_data.bone_rotation = 0
        end
        
        -- change pose params
        -- it's too aestethic
        local anim_breaker = g_vars.anti_aim.misc.animation_breakers
        if g_utils.is_in_selectable(anim_breaker, 5, "Static Legs in air") then
            g_globals.local_player.m_flPoseParameter[6] = 1
        end

        if g_utils.is_in_selectable(anim_breaker, 5, "Static Legs on Walk") and c_anti_aims.utils.good_conditions[7] then
            g_globals.local_player.m_flPoseParameter[8] = 0
            g_globals.local_player.m_flPoseParameter[9] = 0
            g_globals.local_player.m_flPoseParameter[10] = 0
        end

        if g_utils.is_in_selectable(anim_breaker, 5, "Break Movement") then
            g_globals.local_player.m_flPoseParameter[0] = utils.random_float(0.0, 1.0)
        end

        if g_utils.is_in_selectable(anim_breaker, 5, "Warp on Crouch") then
            g_globals.local_player.m_flPoseParameter[16] = 0.2
        end

        if animstate and g_utils.is_in_selectable(anim_breaker, 5, "Pitch on Land") and c_anti_aims.utils.ground_ticks == 3 and animstate.landing then
            g_globals.local_player.m_flPoseParameter[12] = 0.5
        end

        -- this shit is funnier    
        local head_bone         = m_CachedBoneData.bones[8].m
        local bone_breaker      = g_vars.anti_aim.misc.bone_breakers

        if g_utils.is_in_selectable(bone_breaker, 4, "Upside down Head") then
            local angles = render.camera_angles()

            g_utils.angle_matrix(head_bone, vector(90, angles.y + 90, 0))
        end

        if g_utils.is_in_selectable(bone_breaker, 4, "Spinning Head") then
            head_bone[0][3] = head_bone[0][3] + 20 * math.cos(g_globals.anims_data.bone_rotation)
            head_bone[1][3] = head_bone[1][3] + 20 * math.sin(g_globals.anims_data.bone_rotation)
            head_bone[2][3] = head_bone[2][3] + 10
        end

        if g_utils.is_in_selectable(bone_breaker, 4, "Jittering Head") then
            head_bone[1][3] = head_bone[1][3] + utils.random_int(-5, 5)
        end

        if g_utils.is_in_selectable(bone_breaker, 4, "Spinning Body") then
            local chest_bone = m_CachedBoneData.bones[4].m
            chest_bone[0][3] = chest_bone[0][3] + 30 * math.cos(g_globals.anims_data.bone_rotation)
            chest_bone[1][3] = chest_bone[1][3] + 30 * math.sin(g_globals.anims_data.bone_rotation)
            chest_bone[2][3] = chest_bone[2][3] + 10

            local body_bone = m_CachedBoneData.bones[0].m
            body_bone[0][3] = body_bone[0][3] + 30 * math.cos(g_globals.anims_data.bone_rotation)
            body_bone[1][3] = body_bone[1][3] + 30 * math.sin(g_globals.anims_data.bone_rotation)
            body_bone[2][3] = body_bone[2][3] + 10
        end
    end,

    paint_traverse = function(ecx, panel, a, b)
        local original = g_hooks.panel.get_original(41)

        g_panels.focus_overlay_panel    = get_panel(g_panels.focus_overlay_panel, panel, "FocusOverlayPanel")
        g_panels.game_console           = get_panel(g_panels.game_console, panel, "GameConsole")
        g_panels.competition_list       = get_panel(g_panels.competition_list, panel, "CompletionList")
        g_panels.serverbrowser          = get_panel(g_panels.serverbrowser, panel, "CServerBrowserDialog")

        is_console        = g_panels.game_console == panel or g_panels.competition_list == panel
        is_serverbrowser  = g_panels.serverbrowser == panel

        -- if is_console then
        --     materials.get_materials(vgui_materials, false, function(mat)
        --         mat:color_modulate(color(255, 255, 255))
        --     end)
        -- end

        -- https://www.unknowncheats.me/forum/counterstrike-global-offensive/442216-colored-console.html
        original(ecx, panel, a, b)

        if g_panels.focus_overlay_panel == panel then
            g_vfuncs.set_mouse_input_enabled(panel, c_visuals.ui:toggled_draggables())
        end
    end,
}

local hook_player_vmt = function()
    if not g_globals.local_player or not g_globals.local_player:is_alive() then
        return
    end

    local index = g_globals.local_player:get_index()
    local ptr = g_vfuncs.get_client_entity(index)

    if not ptr or g_hooks.player ~= nil then
        return
    end

    g_hooks.player = g_vmt_hook.init(ptr)
    g_hooks.player.hook_func("void(__fastcall*)(void*, void*)", g_hooked.update_clientside_animation, 224)
end

local unhook_player_vmt = function()
    if g_hooks.player then
        g_hooks.player.unhook_all()
        g_hooks.player = nil
    end
end

local hook_panel = function()
    g_hooks.panel = g_vmt_hook.init(g_interfaces.panel)
    g_hooks.panel.hook_func("void(__thiscall*)(void*, unsigned int, bool, bool)", g_hooked.paint_traverse, 41)
end

local unhook_panel = function()
    if g_hooks.panel then
        g_hooks.panel.unhook_all()
        g_hooks.panel = nil
    end
end
-- [[ ************************** LUA HOOKS END ************************** ]] --

-- [[ ************************** CFG ************************** ]] --
g_conditions.init()
c_visuals.ui:init()

g_config_db = db["CHARON_CONFIGS"]

reset_full_config = function()
    -- rage tab
    local rage_main         = g_vars.ragebot.main
    local rage_teleport     = rage_main.teleport_in_air

    rage_main.break_lc_in_air:set(false)

    rage_teleport:set(false)
    rage_teleport.options:set("-")
    rage_teleport.only_on_land(false)

    -- anti-aim tab
    local main      = g_vars.anti_aim.main
    local misc      = g_vars.anti_aim.misc
    local manual    = g_vars.anti_aim.manual
    local setup     = g_vars.anti_aim.setup

    main.enable:set(false)

    misc.animation_breakers:set("-")
    misc.bone_breakers:set("-")
    misc.freestanding:set(false)
    misc.freestanding.options:set("-")
    misc.forward_fix:set(true)

    manual.direction:set("Disabled")
    manual.direction.options:set("-")

    setup.presets:set("None")

    for i = 1, CONDITIONS_AMOUNT do
        local condition_iter = setup.conditions[i]

        condition_iter.pitch:set("Disabled")
        condition_iter.yaw:set("Disabled")
        condition_iter.yaw_base:set("Local view")

        condition_iter.yaw_jitter:set("Disabled")
        condition_iter.yaw_jitter.offset:set(0)
        condition_iter.yaw_jitter.way_angle:set("Default")
        condition_iter.yaw_jitter.first_tick:set(0)
        condition_iter.yaw_jitter.second_tick:set(0)
        condition_iter.yaw_jitter.third_tick:set(0)
        condition_iter.yaw_jitter.tick_delay:set(1)
        condition_iter.yaw_jitter.randomize_tick_order:set(false)

        condition_iter.desync:set(false)
        condition_iter.desync.inverter:set(false)
        condition_iter.desync.left_limit:set(0)
        condition_iter.desync.right_limit:set(0)
        condition_iter.desync.options:set("-")
        condition_iter.desync.lby_mode:set("Disabled")
    end

    -- misc tab
    local ui            = g_vars.misc.ui
    local watermark     = ui.watermark
    local slowdown      = ui.slowdown
    local crosshair     = ui.crosshair
    local scope         = ui.scope
    
    local undercover    = g_vars.misc.undercover

    watermark.enable:set(false)
    watermark.x:set(0)
    watermark.y:set(0)

    slowdown.enable:set(false)
    slowdown.x:set(0)
    slowdown.y:set(0)

    crosshair.enable:set(false)
    crosshair.enable.color:set(color(142, 207, 250, 255))
    crosshair.enable.second_color:set(color(142, 207, 250, 255))
    crosshair.enable.offset:set(0)
    crosshair.enable.other_elements:set("-")
    crosshair.enable.adjust_pos:set(false)

    scope.enable:set(false)
    scope.enable.color:set(color(142, 207, 250, 255))
    scope.enable.invert_color:set(color(0, 0, 0, 0))
    scope.enable.size:set(135)
    scope.enable.gap:set(25)

    undercover.enable:set(false)
    undercover.value:set(" ")
end

default_config = g_tabs.home.configs:button("\f<sad-tear> \vDefault", function()
    -- before loading default config, reset current config
    reset_full_config()

    -- now do full config

    -- rage tab
    local rage_main         = g_vars.ragebot.main
    local rage_teleport     = rage_main.teleport_in_air

    rage_main.break_lc_in_air:set(true)

    -- anti-aim tab
    local main      = g_vars.anti_aim.main
    local misc      = g_vars.anti_aim.misc
    local manual    = g_vars.anti_aim.manual
    local setup     = g_vars.anti_aim.setup

    main.enable:set(true)

    misc.animation_breakers:set("Break Movement", "Warp on Crouch")
    misc.bone_breakers:set("Upside down head")
    misc.freestanding:set(false)
    misc.freestanding.options:set("No At-Targets", "No Jitter", "No Body Jitter")
    misc.forward_fix:set(true)
    
    manual.direction:set("Disabled")
    manual.direction.options:set("No At-Targets", "No Jitter", "No Body Jitter")

    setup.presets:set("Charon Baby")

    -- misc tab
    local ui            = g_vars.misc.ui
    local watermark     = ui.watermark
    local slowdown      = ui.slowdown
    local crosshair     = ui.crosshair
    local scope         = ui.scope

    local screen_size = c_visuals.screen.screen_size

    watermark.enable:set(true)
    watermark.x:set((screen_size.x / 2) - 60)
    watermark.y:set(screen_size.y - 120)

    slowdown.enable:set(true)
    slowdown.enable.color:set(color(240, 142, 142))
    slowdown.x:set((screen_size.x / 2) - 57)
    slowdown.y:set((screen_size.y / 2) + 70)

    crosshair.enable:set(true)
    crosshair.enable.adjust_pos:set(true)
    
    scope.enable:set(true)
    scope.enable.color:set(color(142, 207, 250, 255))
    scope.enable.invert_color:set(color(0, 0, 0, 0))
    scope.enable.size:set(135)
    scope.enable.gap:set(25)
    
    drag_system.on_config_load()
end, true)

local cfg_aa_setup = g_vars.anti_aim.setup

-- 	_:(´ཀ`」 ∠):_
pui.setup({g_vars.anti_aim, g_vars.ragebot, g_vars.misc, g_vars.misc.ui, g_vars.misc.camera, g_vars.misc.undercover,
    cfg_aa_setup.conditions[1], 
    cfg_aa_setup.conditions[2],
    cfg_aa_setup.conditions[3],
    cfg_aa_setup.conditions[4],
    cfg_aa_setup.conditions[5],
    cfg_aa_setup.conditions[6],
    cfg_aa_setup.conditions[7], 
    cfg_aa_setup.conditions[8]})
    
save_config = g_tabs.home.configs:button("\f<file-download> \vSave", function()
    local config            = pui.save()
    local crypted_config    = json.encode(config)

    local xored_config      = g_utils.xor_chars(crypted_config, CONFIG_KEY)
    files.write(CHARON_PATH .. "\\cfg.txt", xored_config)
end, true)

load_config = g_tabs.home.configs:button("\f<file-upload> \vLoad", function()
    local config            = files.read(CHARON_PATH .. "\\cfg.txt")
    local dexored_config    = g_utils.xor_chars(config, CONFIG_KEY)

    local decrypted_config = json.decode(dexored_config)
    if decrypted_config == nil then
        return
    end

    pui.load(decrypted_config)

    drag_system.on_config_load()
end, true)

import_config = g_tabs.home.configs:button("\f<cloud-download-alt> \vImport", function()
    local dexored_config    = g_utils.xor_chars(g_config_db, CONFIG_KEY)

    local decrypted_config = json.decode(dexored_config)
    if decrypted_config == nil then
        return
    end

    pui.load(decrypted_config)

    drag_system.on_config_load()
end, true)

export_config = g_tabs.home.configs:button("\f<cloud-upload-alt> \vExport", function()
    local config            = pui.save()
    local crypted_config    = json.encode(config)

    local xored_config      = g_utils.xor_chars(crypted_config, CONFIG_KEY)
    g_config_db             = xored_config

    -- if user want to copy config, just send it to clipboard
    clipboard.set(g_config_db)
end, true)
-- [[ ************************** CFG END ************************** ]] --

-- [[ ************************** LUA CALLBACKS ************************** ]] --

-- callbacks for undercover
g_vars.misc.undercover.generate:set_callback(function() c_misc.g:generate_undercover() end)

-- callbacks for aspect ratio
local ui_camera = g_vars.misc.camera

ui_camera.aspect_ratio.set_169:set_callback(function()
    ui_camera.aspect_ratio.amount:set(170)
end)

ui_camera.aspect_ratio.set_1610:set_callback(function()
    ui_camera.aspect_ratio.amount:set(160)
end)

ui_camera.aspect_ratio.set_43:set_callback(function()
    ui_camera.aspect_ratio.amount:set(133)
end)

ui_camera.aspect_ratio.set_54:set_callback(function()
    ui_camera.aspect_ratio.amount:set(125)
end)

ui_camera.aspect_ratio.set_11:set_callback(function()
    ui_camera.aspect_ratio.amount:set(100)
end)
-- callbacks end

-- init log
-- TO-DO: animation or smth?? @opai
g_utils.print_log(
    {
        {
            ['color'] = '7affca',
            ['text'] = "Welcome back, ",
        },
        {
            ['color'] = 'FFFFFF',
            ['text'] = g_globals.nickname,
        },
    }
)

events.aim_ack:set(function(shot)
   -- c_misc.g:hitlog(shot)
end)

events.level_init:set(function()
    c_anti_aims.g:reset_info()
    c_visuals.g:reset_info()

    unhook_player_vmt()
end)

events.pre_render:set(function(ctx)
    g_globals.local_player = entity.get_local_player()

    if g_globals.local_player ~= nil then
        if g_globals.local_player:is_alive() then
            g_globals.local_weapon = g_globals.local_player:get_player_weapon(false)
            if g_globals.local_weapon ~= nil then
                g_globals.weapon_info = g_globals.local_weapon:get_weapon_info()
            end
        end
    end
end)

events.render:set(function(ctx)
    g_globals.local_player = entity.get_local_player()

    g_conditions.update()

    if g_globals.local_player ~= nil then
        if g_globals.local_player:is_alive() then
            g_globals.local_weapon = g_globals.local_player:get_player_weapon(false)
            if g_globals.local_weapon ~= nil then
                g_globals.weapon_info = g_globals.local_weapon:get_weapon_info()
            end
        else
            c_anti_aims.g:reset_info()
        end
    end

    if g_vars.home.opai.censor:get() then
        g_vars.home.opai.texture:set_visible(false)
    else
        g_vars.home.opai.texture:set_visible(true)
    end

    if not g_vars.anti_aim.main.enable:get() then
        c_anti_aims.g:reset_info()
    else
        c_anti_aims.g.start_reset = false
    end

    c_visuals.g:run()
    c_misc.g:run()
end)

events.override_view:set(function(ctx)
    c_visuals.smoke:change_fov(ctx)
    c_visuals.camera:run(ctx)
end)

events.round_start:set(function(ctx)
    c_anti_aims.presets:update_random_values()
end)

events.createmove:set(function(cmd)
    g_globals.local_player = entity.get_local_player()
    
    if g_globals.local_player ~= nil then
        if g_globals.local_player:is_alive() then
            g_globals.local_weapon = g_globals.local_player:get_player_weapon(false)
            if g_globals.local_weapon ~= nil then
                g_globals.weapon_info = g_globals.local_weapon:get_weapon_info()
            end
        end
    end

    hook_player_vmt()

    c_ragebot_tweaks.g:run(cmd)
    c_anti_aims.g:run(cmd)

    if globals.choked_commands == 0 then
        g_globals.anims_data.cmd_angles = cmd.view_angles
    end
end)

events.aim_fire:set(function(ctx)
    if g_globals.local_player == nil then
        return
    end

    local eye_pos = g_globals.local_player:get_eye_position()
    local diff = (ctx.aim - eye_pos):angles()

    c_visuals.camera.viewmodel_aim_angles = diff
    c_visuals.camera.viewmodel_aim_time = globals.realtime
end)

hook_panel()

events.shutdown:set(function()
    c_anti_aims.g:reset_all()
    c_visuals.g:reset_all()

    unhook_player_vmt()
    unhook_panel()
end)
-- [[ ************************** LUA CALLBACKS END ************************** ]] --