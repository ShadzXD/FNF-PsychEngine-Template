package utils;
class MemoryUtil
{
    public static final UNITS:Array<String> = ["B", "KB", "MB", "GB", "TB", "PB"];
    /**
     * Custom FormatMemory function because FlxStringUtil.formatBytes() creates an array each frame
     */
	inline public static function formatMemory(bytes:Float):String
    {
        var curUnit = 0;
		while (bytes >= 1024 && curUnit < UNITS.length - 1)
		{
			bytes /= 1024;
			curUnit++;
		}
		return (Math.fround(bytes * 100) / 100) + UNITS[curUnit];
    }
}
