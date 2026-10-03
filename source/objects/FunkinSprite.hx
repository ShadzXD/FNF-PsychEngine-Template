package objects;

import animate.FlxAnimate;
import animate.FlxAnimateFrames;

enum SpriteType {
	SPARROW;
	TEXTUTE_ATLAS;
	PACKER;
	ASEPRITE;
	MULTISPARROW;
}

enum AtlasType {
	SYMBOL;
	TIMELINE;
	FRAME_LABEL;
}

class FunkinSprite extends FlxAnimate {
	public var spriteType:SpriteType = SPARROW;

	/**
	 * Used for Texture Atlas
	 */
	public var textureAtlasType:AtlasType = SYMBOL;
}
