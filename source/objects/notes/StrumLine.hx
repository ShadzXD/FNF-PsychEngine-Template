package objects.notes;

class StrumLine extends FlxTypedGroup<StrumNote> {
	public var playable:Bool = false;

	/**
	 * If the strum is a player strum, this variable allows the strum to hit notes on its own.
	 * Please note that this still has health gain and score gain
	 */
	public var cpuControlled:Bool = false;

	public var downScroll:Bool;

	// keeping this here just in case i end up adding multi key (prob not)
	public final strumCount:Int = 4;

	/**
	 * Whether the strumline should be hidden if the player is using middlescroll
	 */
	public var canBeHidden:Bool = false;

	public var allowStrumlineUnderlay:Bool = false;

	public var introAnimation:Bool = true;

	public var characters:Array<Character>;

	public function new(x:Float, y:Float, player:Int, downScroll:Bool) {
		super();

		for (i in 0...strumCount) {
			var strumArrow:StrumNote = new StrumNote(x, y, i, player);
			strumArrow.downScroll = downScroll;

			var targetAlpha:Float = 1;
			if (introAnimation) {
				strumArrow.alpha = 0;
				FlxTween.tween(strumArrow, {/*y: babyArrow.y + 10,*/ alpha: targetAlpha}, 1, {ease: FlxEase.circOut, startDelay: 0.5 + (0.2 * i)});
			}

			// babyArrow.y -= 10;
			// babyArrow.alpha = targetAlpha;
			add(strumArrow);
			strumArrow.playerPosition();
		}
	}

	public function strumPlayConfirm(id:Int, time:Float) {
		var spr:StrumNote = null;
		spr = this.members[id];

		if (spr != null) {
			spr.playAnim('confirm', true);
			spr.resetAnim = time;
		}
	}
	/*
		public function doIntroTransition(arrow:StrumNote)
		{
		}
	 */
}
