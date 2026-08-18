package psychlua;

import flixel.FlxBasic;
import objects.Character;
import psychlua.LuaUtils;
import psychlua.CustomSubstate;
#if LUA_ALLOWED
import psychlua.FunkinLua;
#end
#if HSCRIPT_ALLOWED
import hxscript.Config as HxScriptConfig;
import hxscript.Script as HxScript;
import hxscript.error.Diagnostic;
import hxscript.error.Printer as HxScriptPrinter;
import hxscript.error.Sink;
import hxscript.runtime.Interp;

typedef HScriptInfos = {
	> haxe.PosInfos,
	var ?funcName:String;
	var ?showLine:Null<Bool>;
	#if LUA_ALLOWED
	var ?isLua:Null<Bool>;
	#end
}

typedef HScriptError = haxe.Exception;

typedef HScriptCall = {
	var funName:String;
	var signature:Dynamic;
	var returnValue:Dynamic;
}

enum abstract HScriptLogLevel(String) from String to String {
	var WARN = 'WARNING';
	var ERROR = 'ERROR';
	var FATAL = 'FATAL';
}

class PsychScript extends HxScript {
	public function new(scriptCode:String, scriptName:String) {
		super(scriptCode, scriptName);
	}

	override public function setDefaults():Void {
		interp.setDefaults(false);
	}
}

class HScript {
	public static var instances:Map<String, HScript> = new Map();

	public static var typedMode(get, set):Bool;

	static function get_typedMode():Bool
		return HxScriptConfig.typedMode;

	static function set_typedMode(v:Bool):Bool
		return HxScriptConfig.typedMode = v;

	public static function logLevel(level:HScriptLogLevel, x:String, ?pos:haxe.PosInfos):Void
		haxe.Log.trace('[$level] $x', pos);

	public static var warn:(String, ?haxe.PosInfos) -> Void = (x, ?pos) -> logLevel(WARN, x, pos);
	public static var error:(String, ?haxe.PosInfos) -> Void = (x, ?pos) -> logLevel(ERROR, x, pos);
	public static var fatal:(String, ?haxe.PosInfos) -> Void = (x, ?pos) -> logLevel(FATAL, x, pos);

	/** The newest diagnostic hxScript produced; it carries more than the exception's message. */
	public static var lastDiagnostic:Diagnostic = null;

	static var watchingDiagnostics:Bool = false;

	/**
	 * Keeps the newest diagnostic so a caught exception can be reported with the source line, the
	 * caret under it and the script call stack. Pushed onto `Sink.onDiagnostic` rather than
	 * registered through `Sink.listen`, because `listen` would stop hxScript printing them too.
	 */
	static function watchDiagnostics():Void {
		if (watchingDiagnostics)
			return;

		watchingDiagnostics = true;
		Sink.onDiagnostic.push(function(d:Diagnostic) lastDiagnostic = d);
	}

	/**
	 * Renders everything hxScript knows about `e`: where it happened, the offending source line with
	 * a caret under the column, any hint, and the call stack across scripts and back into the engine.
	 *
	 * @param e What was caught.
	 * @param context What was being done, prefixed to the message.
	 */
	public static function describe(e:haxe.Exception, ?context:String):String
		return HxScriptPrinter.render(Sink.fromException(e, PRun, context));

	/**
	 * Renders the newest diagnostic, for a failure that reported one without throwing anything
	 * useful (a parse error leaves `program` null and the reason only in the diagnostic).
	 *
	 * @param fallback Used when nothing was reported.
	 */
	public static function describeLast(fallback:String):String
		return lastDiagnostic != null ? HxScriptPrinter.render(lastDiagnostic) : fallback;

	public static function destroyAll():Void {
		for (script in [for (one in instances) one])
			script.destroy();
		instances.clear();
	}

	var script:PsychScript;

	public var scriptCode:String;
	public var filePath:String;
	public var modFolder:String;
	public var returnValue:Dynamic;

	public var name(get, never):String;
	public var interp(get, never):Interp;

	function get_name():String
		return script != null ? script.name : null;

	function get_interp():Interp
		return script != null ? script.interp : null;

	#if LUA_ALLOWED
	public var parentLua:FunkinLua;

	public static function initHaxeModule(parent:FunkinLua) {
		if (parent.hscript == null) {
			trace('initializing haxe interp for: ${parent.scriptName}');
			parent.hscript = new HScript(parent);
		}
	}

	public static function initHaxeModuleCode(parent:FunkinLua, code:String, ?varsToBring:Any = null) {
		var hs:HScript = try parent.hscript catch (e) null;
		if (hs == null) {
			trace('initializing haxe interp for: ${parent.scriptName}');
			try {
				parent.hscript = new HScript(parent, code, varsToBring);
			} catch (e:HScriptError) {
				var pos:HScriptInfos = cast {fileName: parent.scriptName, isLua: true};
				if (parent.lastCalledFunction != '')
					pos.funcName = parent.lastCalledFunction;
				HScript.error(describe(e), pos);
				parent.hscript = null;
			}
		} else {
			try {
				hs.scriptCode = code;
				hs.varsToBring = varsToBring;
				hs.parse(true);
				var ret:Dynamic = hs.execute();
				hs.returnValue = ret;
			} catch (e:HScriptError) {
				var pos:HScriptInfos = cast hs.interp.posInfos();
				pos.isLua = true;
				if (parent.lastCalledFunction != '')
					pos.funcName = parent.lastCalledFunction;
				HScript.error(describe(e), pos);
				hs.returnValue = null;
			}
		}
	}
	#end

	public var origin:String;

	public function new(?parent:Dynamic, ?file:String, ?varsToBring:Any = null, ?manualRun:Bool = false) {
		if (file == null)
			file = '';

		filePath = file;
		if (filePath != null && filePath.length > 0) {
			this.origin = filePath;
			#if MODS_ALLOWED
			var myFolder:Array<String> = filePath.split('/');
			if (myFolder[0] + '/' == Paths.mods()
				&& (Mods.currentModDirectory == myFolder[1] || Mods.getGlobalMods().contains(myFolder[1]))) // is inside mods folder
				this.modFolder = myFolder[1];
			#end
		}
		var scriptThing:String = file;
		var scriptName:String = null;
		if (parent == null && file != null) {
			var f:String = file.replace('\\', '/');
			if (f.contains('/') && !f.contains('\n')) {
				scriptThing = File.getContent(f);
				scriptName = f;
			}
		}
		#if LUA_ALLOWED
		if (scriptName == null && parent != null)
			scriptName = parent.scriptName;
		#end
		if (HxScriptConfig.interpClass != CustomInterp)
			HxScriptConfig.interpClass = CustomInterp;
		watchDiagnostics();

		scriptCode = scriptThing;
		lastDiagnostic = null;
		script = new PsychScript(scriptThing, scriptName != null ? scriptName : 'hscript');
		if (script.program == null)
			throw new HScriptError(describeLast('Failed to parse HScript: ${scriptName != null ? scriptName : filePath}'));

		script.onProgramError = function(e:haxe.Exception) throw e;
		cast(script.interp, CustomInterp).parentInstance = FlxG.state;
		if (scriptName != null)
			instances.set(scriptName, this);
		#if LUA_ALLOWED
		parentLua = parent;
		if (parent != null) {
			this.origin = parent.scriptName;
			this.modFolder = parent.modFolder;
		}
		#end
		preset();
		this.varsToBring = varsToBring;
		if (!manualRun) {
			try {
				var ret:Dynamic = execute();
				returnValue = ret;
			} catch (e:HScriptError) {
				returnValue = null;
				this.destroy();
				throw e;
			} catch (e:Dynamic) {
				// The interpreter can also throw a value that isn't a haxe.Exception
				// (e.g. from Reflect.callMethod inside it); without this catch the
				// partially-constructed HScript leaks and stays in the instances map.
				returnValue = null;
				this.destroy();
				throw e;
			}
		}
	}

	var varsToBring(default, set):Any = null;

	/** Runs the parsed program. Errors are rethrown, the way the callers below expect. */
	public function execute():Dynamic {
		return script != null ? script.start() : null;
	}

	/** Re-parses `scriptCode` in place. `force` is kept for call compatibility. */
	public function parse(?force:Bool = false):Void {
		if (script == null)
			return;

		lastDiagnostic = null;
		if (script.parse(scriptCode) == null)
			throw new HScriptError(describeLast('Failed to parse HScript: $name'));
	}

	public function set(varName:String, value:Dynamic, allowOverride:Bool = true):Void {
		if (script == null)
			return;

		if (!allowOverride && script.variables.exists(varName))
			return;

		script.variables.set(varName, value);
	}

	public function get(field:String):Dynamic {
		if (script == null)
			return null;

		return script.variables.exists(field) ? script.variables.get(field) : script.interp.getLocal(field);
	}

	public function exists(field:String):Bool {
		if (script == null)
			return false;

		return script.variables.exists(field) || script.interp.getLocal(field) != null;
	}

	public function preset() {

		// Some very commonly used classes
		set('Type', Type);
		#if sys
		set('File', File);
		set('FileSystem', FileSystem);
		#end
		set('FlxG', flixel.FlxG);
		set('FlxMath', flixel.math.FlxMath);
		set('FlxSprite', flixel.FlxSprite);
		set('FlxText', flixel.text.FlxText);
		set('FlxCamera', flixel.FlxCamera);
		set('PsychCamera', backend.PsychCamera);
		set('FlxTimer', flixel.util.FlxTimer);
		set('FlxTween', flixel.tweens.FlxTween);
		set('FlxEase', flixel.tweens.FlxEase);
		set('FlxColor', CustomFlxColor);
		set('Countdown', backend.BaseStage.Countdown);
		set('PlayState', PlayState);
		set('Paths', Paths);
		set('Conductor', Conductor);
		set('ClientPrefs', ClientPrefs);
		#if ACHIEVEMENTS_ALLOWED
		set('Achievements', Achievements);
		#end
		set('Character', Character);
		set('Alphabet', Alphabet);
		set('Note', objects.Note);
		set('CustomSubstate', CustomSubstate);
		#if (!flash && sys)
		set('FlxRuntimeShader', flixel.addons.display.FlxRuntimeShader);
		set('ErrorHandledRuntimeShader', shaders.ErrorHandledShader.ErrorHandledRuntimeShader);
		#end
		set('ShaderFilter', openfl.filters.ShaderFilter);
		set('StringTools', StringTools);
		#if flxanimate
		set('FlxAnimate', FlxAnimate);
		#end

		// Functions & Variables
		set('setVar', function(name:String, value:Dynamic) {
			MusicBeatState.getVariables().set(name, value);
			return value;
		});
		set('getVar', function(name:String) {
			var result:Dynamic = null;
			if (MusicBeatState.getVariables().exists(name))
				result = MusicBeatState.getVariables().get(name);
			return result;
		});
		set('removeVar', function(name:String) {
			if (MusicBeatState.getVariables().exists(name)) {
				MusicBeatState.getVariables().remove(name);
				return true;
			}
			return false;
		});
		set('debugPrint', function(text:String, ?color:FlxColor = null) {
			if (color == null)
				color = FlxColor.WHITE;
			PlayState.instance.addTextToDebug(text, color);
		});
		set('getModSetting', function(saveTag:String, ?modName:String = null) {
			if (modName == null) {
				if (this.modFolder == null) {
					HScript.error('getModSetting: Argument #2 is null and script is not inside a packed Mod folder!', this.interp.posInfos());
					return null;
				}
				modName = this.modFolder;
			}
			return LuaUtils.getModSetting(saveTag, modName);
		});

		// Keyboard & Gamepads
		set('keyboardJustPressed', function(name:String) return Reflect.getProperty(FlxG.keys.justPressed, name));
		set('keyboardPressed', function(name:String) return Reflect.getProperty(FlxG.keys.pressed, name));
		set('keyboardReleased', function(name:String) return Reflect.getProperty(FlxG.keys.justReleased, name));

		set('anyGamepadJustPressed', function(name:String) return FlxG.gamepads.anyJustPressed(name));
		set('anyGamepadPressed', function(name:String) return FlxG.gamepads.anyPressed(name));
		set('anyGamepadReleased', function(name:String) return FlxG.gamepads.anyJustReleased(name));

		set('gamepadAnalogX', function(id:Int, ?leftStick:Bool = true) {
			var controller = FlxG.gamepads.getByID(id);
			if (controller == null)
				return 0.0;

			return controller.getXAxis(leftStick ? LEFT_ANALOG_STICK : RIGHT_ANALOG_STICK);
		});
		set('gamepadAnalogY', function(id:Int, ?leftStick:Bool = true) {
			var controller = FlxG.gamepads.getByID(id);
			if (controller == null)
				return 0.0;

			return controller.getYAxis(leftStick ? LEFT_ANALOG_STICK : RIGHT_ANALOG_STICK);
		});
		set('gamepadJustPressed', function(id:Int, name:String) {
			var controller = FlxG.gamepads.getByID(id);
			if (controller == null)
				return false;

			return Reflect.getProperty(controller.justPressed, name) == true;
		});
		set('gamepadPressed', function(id:Int, name:String) {
			var controller = FlxG.gamepads.getByID(id);
			if (controller == null)
				return false;

			return Reflect.getProperty(controller.pressed, name) == true;
		});
		set('gamepadReleased', function(id:Int, name:String) {
			var controller = FlxG.gamepads.getByID(id);
			if (controller == null)
				return false;

			return Reflect.getProperty(controller.justReleased, name) == true;
		});

		set('keyJustPressed', function(name:String = '') {
			name = name.toLowerCase();
			switch (name) {
				case 'left':
					return Controls.instance.NOTE_LEFT_P;
				case 'down':
					return Controls.instance.NOTE_DOWN_P;
				case 'up':
					return Controls.instance.NOTE_UP_P;
				case 'right':
					return Controls.instance.NOTE_RIGHT_P;
				default:
					return Controls.instance.justPressed(name);
			}
			return false;
		});
		set('keyPressed', function(name:String = '') {
			name = name.toLowerCase();
			switch (name) {
				case 'left':
					return Controls.instance.NOTE_LEFT;
				case 'down':
					return Controls.instance.NOTE_DOWN;
				case 'up':
					return Controls.instance.NOTE_UP;
				case 'right':
					return Controls.instance.NOTE_RIGHT;
				default:
					return Controls.instance.pressed(name);
			}
			return false;
		});
		set('keyReleased', function(name:String = '') {
			name = name.toLowerCase();
			switch (name) {
				case 'left':
					return Controls.instance.NOTE_LEFT_R;
				case 'down':
					return Controls.instance.NOTE_DOWN_R;
				case 'up':
					return Controls.instance.NOTE_UP_R;
				case 'right':
					return Controls.instance.NOTE_RIGHT_R;
				default:
					return Controls.instance.justReleased(name);
			}
			return false;
		});

		// For adding your own callbacks
		// not very tested but should work
		#if LUA_ALLOWED
		set('createGlobalCallback', function(name:String, func:Dynamic) {
			for (script in PlayState.instance.luaArray)
				if (script != null && script.lua != null && !script.closed)
					Lua_helper.add_callback(script.lua, name, func);

			FunkinLua.customFunctions.set(name, func);
		});

		// this one was tested
		set('createCallback', function(name:String, func:Dynamic, ?funk:FunkinLua = null) {
			if (funk == null)
				funk = parentLua;

			if (funk != null)
				funk.addLocalCallback(name, func);
			else
				HScript.error('createCallback ($name): 3rd argument is null', this.interp.posInfos());
		});
		#end

		set('addHaxeLibrary', function(libName:String, ?libPackage:String = '') {
			try {
				var str:String = '';
				if (libPackage.length > 0)
					str = libPackage + '.';

				set(libName, Type.resolveClass(str + libName));
			} catch (e:HScriptError) {
				HScript.error(describe(e), this.interp.posInfos());
			}
		});
		#if LUA_ALLOWED
		set('parentLua', parentLua);
		#else
		set('parentLua', null);
		#end
		set('this', this);
		set('game', FlxG.state);
		set('controls', Controls.instance);

		set('buildTarget', LuaUtils.getBuildTarget());
		set('customSubstate', CustomSubstate.instance);
		set('customSubstateName', CustomSubstate.name);

		set('Function_Stop', LuaUtils.Function_Stop);
		set('Function_Continue', LuaUtils.Function_Continue);
		set('Function_StopLua', LuaUtils.Function_StopLua); // doesnt do much cuz HScript has a lower priority than Lua
		set('Function_StopHScript', LuaUtils.Function_StopHScript);
		set('Function_StopAll', LuaUtils.Function_StopAll);
	}

	#if LUA_ALLOWED
	public static function implement(funk:FunkinLua) {
		funk.addLocalCallback("runHaxeCode",
			function(codeToRun:String, ?varsToBring:Any = null, ?funcToRun:String = null, ?funcArgs:Array<Dynamic> = null):Dynamic {
				initHaxeModuleCode(funk, codeToRun, varsToBring);
				if (funk.hscript != null) {
					final retVal:HScriptCall = funk.hscript.call(funcToRun, funcArgs);
					if (retVal != null) {
						return (LuaUtils.isLuaSupported(retVal.returnValue)) ? retVal.returnValue : null;
					} else if (funk.hscript.returnValue != null) {
						return funk.hscript.returnValue;
					}
				}
				return null;
			});

		funk.addLocalCallback("runHaxeFunction", function(funcToRun:String, ?funcArgs:Array<Dynamic> = null) {
			if (funk.hscript != null) {
				final retVal:HScriptCall = funk.hscript.call(funcToRun, funcArgs);
				if (retVal != null) {
					return (LuaUtils.isLuaSupported(retVal.returnValue)) ? retVal.returnValue : null;
				}
			} else {
				var pos:HScriptInfos = cast {fileName: funk.scriptName, showLine: false};
				if (funk.lastCalledFunction != '')
					pos.funcName = funk.lastCalledFunction;
				HScript.error("runHaxeFunction: HScript has not been initialized yet! Use \"runHaxeCode\" to initialize it", pos);
			}
			return null;
		});
		// This function is unnecessary because import already exists in HScript as a native feature
		funk.addLocalCallback("addHaxeLibrary", function(libName:String, ?libPackage:String = '') {
			var str:String = '';
			if (libPackage.length > 0)
				str = libPackage + '.';
			else if (libName == null)
				libName = '';

			var c:Dynamic = Type.resolveClass(str + libName);
			if (c == null)
				c = Type.resolveEnum(str + libName);

			if (funk.hscript == null)
				initHaxeModule(funk);

			// initHaxeModule may fail to assign funk.hscript (e.g. constructor
			// throws); without this guard the next line NPEs.
			if (funk.hscript == null)
				return;

			var pos:HScriptInfos = cast funk.hscript.interp.posInfos();
			pos.showLine = false;
			if (funk.lastCalledFunction != '')
				pos.funcName = funk.lastCalledFunction;

			try {
				if (c != null)
					funk.hscript.set(libName, c);
			} catch (e:HScriptError) {
				HScript.error(describe(e), pos);
			}
			FunkinLua.lastCalledScript = funk;
			if (FunkinLua.getBool('luaDebugMode') && FunkinLua.getBool('luaDeprecatedWarnings'))
				HScript.warn("addHaxeLibrary is deprecated! Import classes through \"import\" in HScript!", pos);
		});
	}
	#end

	public function call(funcToRun:String, ?args:Array<Dynamic>):HScriptCall {
		if (funcToRun == null || script == null)
			return null;

		if (!exists(funcToRun)) {
			HScript.error('No function named: $funcToRun', this.interp.posInfos());
			return null;
		}

		try {
			var func:Dynamic = get(funcToRun); // function signature
			if (!Reflect.isFunction(func)) {
				// `exists()` returns true for any variable; Reflect.callMethod
				// on a non-function value throws a generic exception that the
				// catch arm below doesn't cover, which then propagates out and
				// breaks the calling Lua frame.
				return null;
			}
			final ret = Reflect.callMethod(script.interp, func, args ?? []);
			return {funName: funcToRun, signature: func, returnValue: ret};
		} catch (e:HScriptError) {
			var pos:HScriptInfos = cast this.interp.posInfos();
			pos.showLine = false;
			pos.funcName = funcToRun;
			#if LUA_ALLOWED
			if (parentLua != null) {
				pos.isLua = true;
				if (parentLua.lastCalledFunction != '')
					pos.funcName = parentLua.lastCalledFunction;
			}
			#end
			HScript.error(describe(e), pos);
		}
		return null;
	}

	public function destroy() {
		if (name != null)
			instances.remove(name);

		origin = null;
		#if LUA_ALLOWED parentLua = null; #end
		if (script != null) {
			script.variables.clear();
			script = null;
		}
	}

	function set_varsToBring(values:Any) {
		if (varsToBring != null)
			for (key in Reflect.fields(varsToBring))
				if (exists(key.trim()))
					interp.variables.remove(key.trim());

		if (values != null) {
			for (key in Reflect.fields(values)) {
				key = key.trim();
				set(key, Reflect.field(values, key));
			}
		}

		return varsToBring = values;
	}
}

class CustomFlxColor {
	public static var TRANSPARENT(default, null):Int = FlxColor.TRANSPARENT;
	public static var BLACK(default, null):Int = FlxColor.BLACK;
	public static var WHITE(default, null):Int = FlxColor.WHITE;
	public static var GRAY(default, null):Int = FlxColor.GRAY;

	public static var GREEN(default, null):Int = FlxColor.GREEN;
	public static var LIME(default, null):Int = FlxColor.LIME;
	public static var YELLOW(default, null):Int = FlxColor.YELLOW;
	public static var ORANGE(default, null):Int = FlxColor.ORANGE;
	public static var RED(default, null):Int = FlxColor.RED;
	public static var PURPLE(default, null):Int = FlxColor.PURPLE;
	public static var BLUE(default, null):Int = FlxColor.BLUE;
	public static var BROWN(default, null):Int = FlxColor.BROWN;
	public static var PINK(default, null):Int = FlxColor.PINK;
	public static var MAGENTA(default, null):Int = FlxColor.MAGENTA;
	public static var CYAN(default, null):Int = FlxColor.CYAN;

	public static function fromInt(Value:Int):Int
		return cast FlxColor.fromInt(Value);

	public static function fromRGB(Red:Int, Green:Int, Blue:Int, Alpha:Int = 255):Int
		return cast FlxColor.fromRGB(Red, Green, Blue, Alpha);

	public static function fromRGBFloat(Red:Float, Green:Float, Blue:Float, Alpha:Float = 1):Int
		return cast FlxColor.fromRGBFloat(Red, Green, Blue, Alpha);

	public static inline function fromCMYK(Cyan:Float, Magenta:Float, Yellow:Float, Black:Float, Alpha:Float = 1):Int
		return cast FlxColor.fromCMYK(Cyan, Magenta, Yellow, Black, Alpha);

	public static function fromHSB(Hue:Float, Sat:Float, Brt:Float, Alpha:Float = 1):Int
		return cast FlxColor.fromHSB(Hue, Sat, Brt, Alpha);

	public static function fromHSL(Hue:Float, Sat:Float, Light:Float, Alpha:Float = 1):Int
		return cast FlxColor.fromHSL(Hue, Sat, Light, Alpha);

	public static function fromString(str:String):Int
		return cast FlxColor.fromString(str);
}

class CustomInterp extends Interp {
	public var parentInstance(default, set):Dynamic = null;

	private var _instanceFields:Array<String> = [];

	function set_parentInstance(inst:Dynamic):Dynamic {
		parentInstance = inst;
		_instanceFields = (inst == null) ? [] : Type.getInstanceFields(Type.getClass(inst));
		return inst;
	}

	public function new(?environment:hxscript.Environment, ?parent:Dynamic) {
		super(environment, parent);
	}

	override public function resolve(id:String):Dynamic {
		// Scripts reach the running state's fields bare (`curBeat`, `boyfriend`). Everything the
		// interpreter can resolve on its own still wins, so a local never loses to a state field.
		if (parentInstance != null
			&& _instanceFields.contains(id)
			&& !locals.exists(id)
			&& !variables.exists(id)
			&& !imports.exists(id))
			return Reflect.getProperty(parentInstance, id);

		return super.resolve(id);
	}
}

#else
class HScript {
	#if LUA_ALLOWED
	public static function implement(funk:FunkinLua) {
		funk.addLocalCallback("runHaxeCode",
			function(codeToRun:String, ?varsToBring:Any = null, ?funcToRun:String = null, ?funcArgs:Array<Dynamic> = null):Dynamic {
				PlayState.instance.addTextToDebug('HScript is not supported on this platform!', FlxColor.RED);
				return null;
			});
		funk.addLocalCallback("runHaxeFunction", function(funcToRun:String, ?funcArgs:Array<Dynamic> = null) {
			PlayState.instance.addTextToDebug('HScript is not supported on this platform!', FlxColor.RED);
			return null;
		});
		funk.addLocalCallback("addHaxeLibrary", function(libName:String, ?libPackage:String = '') {
			PlayState.instance.addTextToDebug('HScript is not supported on this platform!', FlxColor.RED);
			return null;
		});
	}
	#end
}
#end
