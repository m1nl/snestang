library IEEE;
use IEEE.Std_Logic_1164.all;
library STD;
use ieee.numeric_std.all;

package PPU_PKG is  

	constant DOT_NUM: unsigned(8 downto 0) := "101010100"; --340 
	constant LINE_NUM_NTSC: unsigned(8 downto 0) := "100000110"; --262 
	constant LINE_NUM_PAL: unsigned(8 downto 0) := "100111000"; --312 

	constant LINE_VSYNC_NTSC: unsigned(8 downto 0) := "011101100"; --236 
	constant LINE_VSYNC_PAL: unsigned(8 downto 0)  := "100000100"; --260 

	constant HSYNC_START: unsigned(8 downto 0) := "100101000"; --296 
	constant VSYNC_I_HSTART: unsigned(8 downto 0) := "001111110"; --126 

	constant BG1: integer range 0 to 3 := 0; 
	constant BG2: integer range 0 to 3 := 1; 
	constant BG3: integer range 0 to 3 := 2; 
	constant BG4: integer range 0 to 3 := 3; 
	
	type BgFetch_t is (
		BF_TILEMAP,
		BF_TILEDAT0,
		BF_TILEDAT1,
		BF_TILEDAT2,
		BF_TILEDAT3,
		BF_TILEDATM7,
		BF_OPT0,
		BF_OPT1,
		BF_MODE7
	);
	
	-- Keep the fetch schedule as two scalar tables.  Gowin's VHDL frontend
	-- mishandles the original two-dimensional array of records in some builds.
	type BgFetchBgTbl_t is array(0 to 7, 0 to 7) of integer range 0 to 3;
	type BgFetchModeTbl_t is array(0 to 7, 0 to 7) of BgFetch_t;

	constant BF_BG_TBL: BgFetchBgTbl_t := (
	    (BG4, BG3, BG2, BG1, BG4, BG3, BG2, BG1), (BG3, BG2, BG1, BG3, BG2, BG2, BG1, BG1),
	    (BG2, BG1, BG3, BG3, BG2, BG2, BG1, BG1), (BG2, BG1, BG2, BG2, BG1, BG1, BG1, BG1),
	    (BG2, BG1, BG3, BG2, BG1, BG1, BG1, BG1), (BG2, BG1, BG2, BG2, BG1, BG1, BG1, BG1),
	    (BG2, BG1, BG3, BG3, BG1, BG1, BG1, BG1), (BG1, BG1, BG1, BG1, BG1, BG1, BG1, BG1)
    );

	constant BF_MODE_TBL: BgFetchModeTbl_t := (
	    (BF_TILEMAP,   BF_TILEMAP,   BF_TILEMAP,   BF_TILEMAP,   BF_TILEDAT0,  BF_TILEDAT0,  BF_TILEDAT0,  BF_TILEDAT0),
	    (BF_TILEMAP,   BF_TILEMAP,   BF_TILEMAP,   BF_TILEDAT0,  BF_TILEDAT0,  BF_TILEDAT1,  BF_TILEDAT0,  BF_TILEDAT1),
	    (BF_TILEMAP,   BF_TILEMAP,   BF_OPT0,      BF_OPT1,      BF_TILEDAT0,  BF_TILEDAT1,  BF_TILEDAT0,  BF_TILEDAT1),
	    (BF_TILEMAP,   BF_TILEMAP,   BF_TILEDAT0,  BF_TILEDAT1,  BF_TILEDAT0,  BF_TILEDAT1,  BF_TILEDAT2,  BF_TILEDAT3),
	    (BF_TILEMAP,   BF_TILEMAP,   BF_OPT0,      BF_TILEDAT0,  BF_TILEDAT0,  BF_TILEDAT1,  BF_TILEDAT2,  BF_TILEDAT3),
	    (BF_TILEMAP,   BF_TILEMAP,   BF_TILEDAT0,  BF_TILEDAT1,  BF_TILEDAT0,  BF_TILEDAT1,  BF_TILEDAT2,  BF_TILEDAT3),
	    (BF_TILEMAP,   BF_TILEMAP,   BF_OPT0,      BF_OPT1,      BF_TILEDAT0,  BF_TILEDAT1,  BF_TILEDAT2,  BF_TILEDAT3),
	    (BF_TILEDATM7, BF_TILEDATM7, BF_TILEDATM7, BF_TILEDATM7, BF_TILEDATM7, BF_TILEDATM7, BF_TILEDATM7, BF_TILEDATM7)
    );
	
	type BgScAddr_t is array(0 to 3) of std_logic_vector(5 downto 0);
	type BgScSize_t is array(0 to 3) of std_logic_vector(1 downto 0);
	type BgTileAddr_t is array(0 to 3) of std_logic_vector(3 downto 0);
	type BgScroll_t is array(0 to 3) of std_logic_vector(9 downto 0);
	type BgData_t is array(0 to 7) of std_logic_vector(15 downto 0);
	type BgTileInfo_t is array(0 to 3) of std_logic_vector(15 downto 0);
	type BgTileAtr_t is array(0 to 3) of std_logic_vector(3 downto 0);
	
	type BgPlanes_t is array(0 to 11) of std_logic_vector(7 downto 0);
	type BgTilePlanesBuf_t is array(0 to 1) of BgPlanes_t;
	type BgTileAtrBuf_t is array(0 to 1) of BgTileAtr_t;


	constant BG_FETCH_START		: unsigned(8 downto 0) := "000000000"; 	--0 
	constant BG_FETCH_END		: unsigned(8 downto 0) := "100001111"; 	--(256+16)-1=271
	constant M7_FETCH_START		: unsigned(8 downto 0) := "000001111"; 	--15
	constant M7_FETCH_END		: unsigned(8 downto 0) := "100001110"; 	--(15+256)-1=270
	constant M7_XY_LATCH			: unsigned(8 downto 0) := "000001011"; 	--11
	constant SPR_GET_PIX_START	: unsigned(8 downto 0) := "000010000"; 	--16 
	constant SPR_GET_PIX_END	: unsigned(8 downto 0) := "100001111"; 	--(16+256)-1=271
	constant BG_GET_PIX_START	: unsigned(8 downto 0) := "000010001"; 	--17
	constant BG_GET_PIX_END		: unsigned(8 downto 0) := "100010000"; 	--(17+256)-1=272
	constant BG_MATH_START		: unsigned(8 downto 0) := "000010010"; 	--18
	constant BG_MATH_END			: unsigned(8 downto 0) := "100010001"; 	--(18+256)-1=273
	constant BG_OUT_START		: unsigned(8 downto 0) := "000010011"; 	--19
	constant BG_OUT_END			: unsigned(8 downto 0) := "100010010"; 	--(19+256)-1=274
	
	constant OBJ_RANGE_START	: unsigned(8 downto 0) := "000000000"; 	--0 
	constant OBJ_RANGE_END		: unsigned(8 downto 0) := "011111111"; 	--256-1=255
	constant OBJ_TIME_START		: unsigned(8 downto 0) := "100001110"; 	--(16+256)-2=270 
	constant OBJ_TIME_END		: unsigned(8 downto 0) := "101010001"; 	--(16+256+68)-2-1=337 
	constant OBJ_FETCH_START	: unsigned(8 downto 0) := "100010000"; 	--(16+256)=272
	constant OBJ_FETCH_END		: unsigned(8 downto 0) := "101010011"; 	--(16+256+68)-1=339
	
	type RangeOam_t is array(0 to 31) of std_logic_vector(6 downto 0);
	
	type SprSize_t is array(0 to 15) of unsigned(7 downto 0);
	constant SPR_WIDTH: SprSize_t := (
	x"07", x"07", x"07", x"0F", x"0F", x"1F", x"0F", x"0F",
	x"0F", x"1F", x"3F", x"1F", x"3F", x"3F", x"1F", x"1F"
	);
	constant SPR_HEIGHT: SprSize_t := (
	x"07", x"07", x"07", x"0F", x"0F", x"1F", x"1F", x"1F",
	x"0F", x"1F", x"3F", x"1F", x"3F", x"3F", x"3F", x"1F"
	);
	function SprWidth(size: std_logic_vector(3 downto 0)) return unsigned;
	function SprHeight(size: std_logic_vector(3 downto 0)) return unsigned;
		
	function FlipPlane(bp: std_logic_vector(7 downto 0); flip: std_logic) return std_logic_vector;
	function FlipBGPlaneHR(bp: std_logic_vector(15 downto 0); flip: std_logic; main: std_logic) return std_logic_vector;
									  
	function AddSub(a: unsigned(4 downto 0); b: unsigned(4 downto 0);
						 add: std_logic; half: std_logic) return unsigned;
	function GetDCM(a: std_logic_vector(10 downto 0)) return std_logic_vector;
	function Bright(mb: std_logic_vector(3 downto 0); b: unsigned(4 downto 0)) return std_logic_vector;
	
	function Mode7Clip(a: signed(13 downto 0)) return signed;


	component ppucgram
		port (
			clock    : in  std_logic;
			address_a : in  std_logic_vector(7 downto 0);
			address_b : in  std_logic_vector(7 downto 0);
			data_a    : in  std_logic_vector(14 downto 0);
			data_b    : in  std_logic_vector(14 downto 0);
			wren_a    : in  std_logic;
			wren_b    : in  std_logic;
			q_a       : out std_logic_vector(14 downto 0);
			q_b       : out std_logic_vector(14 downto 0)
		);
	end component;

component ppuhoam
    port (
        clock   : in  std_logic;
        address : in  std_logic_vector(4 downto 0);
        data    : in  std_logic_vector(7 downto 0);
        wren    : in  std_logic;
        q       : out std_logic_vector(7 downto 0)
    );
end component;
	component ppuoam
		port (
			clock     : in  std_logic;
			address_a : in  std_logic_vector(7 downto 0);
			address_b : in  std_logic_vector(6 downto 0);
			data_a    : in  std_logic_vector(15 downto 0);
			wren_a    : in  std_logic;
			q_a       : out std_logic_vector(15 downto 0);
			q_b       : out std_logic_vector(31 downto 0)
		);
	end component;

component ppusprbuf
    port (
        clock     : in  std_logic;
        address_a : in  std_logic_vector(7 downto 0);
        address_b : in  std_logic_vector(7 downto 0);
        data_a    : in  std_logic_vector(8 downto 0);
        wren_a    : in  std_logic;
        wren_b    : in  std_logic;
        q_b       : out std_logic_vector(8 downto 0)
    );
end component;

component ppurangetbl
    port (
        clock     : in  std_logic;
        rdaddress : in  std_logic_vector(4 downto 0);
        wraddress : in  std_logic_vector(4 downto 0);
        data      : in  std_logic_vector(6 downto 0);
        wren      : in  std_logic;
        q         : out std_logic_vector(6 downto 0)
    );
end component;


end PPU_PKG;

package body PPU_PKG is

	function FlipPlane(bp: std_logic_vector(7 downto 0); flip: std_logic) return std_logic_vector is
		variable res: std_logic_vector(7 downto 0); 
	begin
		if flip = '1' then
			res := bp(0)&bp(1)&bp(2)&bp(3)&bp(4)&bp(5)&bp(6)&bp(7);
		else
			res := bp;
		end if;
		return res;
	end function;
	
	function FlipBGPlaneHR(bp: std_logic_vector(15 downto 0); flip: std_logic; main: std_logic) return std_logic_vector is
		variable res: std_logic_vector(7 downto 0); 
		variable temp: std_logic_vector(15 downto 0); 
	begin
		if flip = '1' then
			temp := bp(0)&bp(1)&bp(2)&bp(3)&bp(4)&bp(5)&bp(6)&bp(7)&bp(8)&bp(9)&bp(10)&bp(11)&bp(12)&bp(13)&bp(14)&bp(15);
		else
			temp := bp;
		end if;
		if main = '1' then
			res := temp(14)&temp(12)&temp(10)&temp(8)&temp(6)&temp(4)&temp(2)&temp(0);
		else
			res := temp(15)&temp(13)&temp(11)&temp(9)&temp(7)&temp(5)&temp(3)&temp(1);
		end if;
		return res;
	end function;
	
	function SprWidth(size: std_logic_vector(3 downto 0)) return unsigned is
		variable temp: unsigned(7 downto 0); 
	begin
		temp := SPR_WIDTH(to_integer(unsigned(size)));
		return temp(5 downto 0);
	end function;
	
	function SprHeight(size: std_logic_vector(3 downto 0)) return unsigned is
		variable temp: unsigned(7 downto 0); 
	begin
		temp := SPR_HEIGHT(to_integer(unsigned(size)));
		return temp(5 downto 0);
	end function;
	
	function AddSub(a: unsigned(4 downto 0); 
						 b: unsigned(4 downto 0);
						 add: std_logic;
						 half: std_logic) return unsigned is
		variable temp: unsigned(5 downto 0); 
		variable res: unsigned(4 downto 0); 
	begin
		if add = '1' then
			temp := resize(a,temp'length) + resize(b,temp'length);
			if half = '1' then
				temp := "0"&temp(5 downto 1);
			elsif temp(5) = '1' then
				temp := "111111";
			end if;
		else
			temp := resize(a,temp'length) - resize(b,temp'length);
			if temp(5) = '1' then
				temp := "000000";
			elsif half = '1' then
				temp := "0"&temp(5 downto 1);
			end if;
		end if;
		
		res := temp(4 downto 0);
		return res;
	end function;

	function GetDCM(a: std_logic_vector(10 downto 0)) return std_logic_vector is
		variable res: std_logic_vector(14 downto 0); 
	begin
		res := a(7 downto 6) & a(10) & "00" & a(5 downto 3) & a(9) & "0" & a(2 downto 0) & a(8) & "0";
		return res;
	end function;

	function Bright(mb: std_logic_vector(3 downto 0); b: unsigned(4 downto 0)) return std_logic_vector is
		variable temp: unsigned(8 downto 0); 
		variable res: std_logic_vector(7 downto 0); 
	begin
		temp := b * unsigned(mb) + resize(b,temp'length);
		if mb = x"0" then
			res := (others => '0');
		else
			--res := std_logic_vector(temp(8 downto 1) + temp(8 downto 6));
            res := std_logic_vector(temp(8 downto 4)) & "000";
		end if;
		return res;
	end function;

	function Mode7Clip(a: signed(13 downto 0)) return signed is
		variable res: signed(15 downto 0); 
	begin
		res := (0 to 5 => a(13)) & a(9 downto 0);
		return res;
	end function;

end package body PPU_PKG;
