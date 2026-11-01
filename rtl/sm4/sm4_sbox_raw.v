// =============================================================================
// sm4_sbox_raw.v -- SM4 S 盒纯查询 module（自动生成）
// 来源: rtl\sm4\sm4_engine_sys.v
// 生成脚本: .workbuddy/tmp/gen_sbox_raw.py
// 铁律: 禁止手工誊抄 —— 修改 S 盒必须改 sm4_engine_sys.v 后重跑本脚本
// 已校验: 256 项双射，S[0x00]=0xD6, S[0x01]=0x90, S[0x02]=0xE9,
//           S[0x04]=0xCC, S[0x80]=0xEA (GB/T 32907)
// =============================================================================

module sm4_sbox_raw (
    input  wire        clk,
    input  wire        en,
    input  wire [7:0]  x,
    output reg [7:0]   y
);
    
    // BRAM 存储 S 盒真值表
    (* ram_style="block" *) reg [7:0] sbox_rom [0:255];
    
    // 初始化 S 盒
    initial begin
        sbox_rom[0]   = 8'hd6;  sbox_rom[1]   = 8'h90;  sbox_rom[2]   = 8'h e9;  sbox_rom[3]   = 8'hfe;
        sbox_rom[4]   = 8'hcc;  sbox_rom[5]   = 8'he1;  sbox_rom[6]   = 8'h3d;  sbox_rom[7]   = 8'hb7;
        sbox_rom[8]   = 8'h16;  sbox_rom[9]   = 8'hb6;  sbox_rom[10]  = 8'h14;  sbox_rom[11]  = 8'hc2;
        sbox_rom[12]  = 8'h28;  sbox_rom[13]  = 8'hfb;  sbox_rom[14]  = 8'h2c;  sbox_rom[15]  = 8'h05;
        sbox_rom[16]  = 8'h2b;  sbox_rom[17]  = 8'h67;  sbox_rom[18]  = 8'h9a;  sbox_rom[19]  = 8'h76;
        sbox_rom[20]  = 8'h2a;  sbox_rom[21]  = 8'hbe;  sbox_rom[22]  = 8'h04;  sbox_rom[23]  = 8'hc3;
        sbox_rom[24]  = 8'haa;  sbox_rom[25]  = 8'h44;  sbox_rom[26]  = 8'h13;  sbox_rom[27]  = 8'h26;
        sbox_rom[28]  = 8'h49;  sbox_rom[29]  = 8'h86;  sbox_rom[30]  = 8'h06;  sbox_rom[31]  = 8'h99;
        sbox_rom[32]  = 8'h9c;  sbox_rom[33]  = 8'h42;  sbox_rom[34]  = 8'h50;  sbox_rom[35]  = 8'hf4;
        sbox_rom[36]  = 8'h91;  sbox_rom[37]  = 8'h ef;  sbox_rom[38]  = 8'h98;  sbox_rom[39]  = 8'h7a;
        sbox_rom[40]  = 8'h33;  sbox_rom[41]  = 8'h54;  sbox_rom[42]  = 8'h0b;  sbox_rom[43]  = 8'h43;
        sbox_rom[44]  = 8'hed;  sbox_rom[45]  = 8'hcf;  sbox_rom[46]  = 8'hac;  sbox_rom[47]  = 8'h62;
        sbox_rom[48]  = 8'h e4;  sbox_rom[49]  = 8'hb3;  sbox_rom[50]  = 8'h1c;  sbox_rom[51]  = 8'h a9;
        sbox_rom[52]  = 8'h c9;  sbox_rom[53]  = 8'h08;  sbox_rom[54]  = 8'h e8;  sbox_rom[55]  = 8'h95;
        sbox_rom[56]  = 8'h80;  sbox_rom[57]  = 8'hdf;  sbox_rom[58]  = 8'h94;  sbox_rom[59]  = 8'hfa;
        sbox_rom[60]  = 8'h75;  sbox_rom[61]  = 8'h8f;  sbox_rom[62]  = 8'h3f;  sbox_rom[63]  = 8'h a6;
        sbox_rom[64]  = 8'h47;  sbox_rom[65]  = 8'h07;  sbox_rom[66]  = 8'h a7;  sbox_rom[67]  = 8'hfc;
        sbox_rom[68]  = 8'hf3;  sbox_rom[69]  = 8'h73;  sbox_rom[70]  = 8'h17;  sbox_rom[71]  = 8'hba;
        sbox_rom[72]  = 8'h83;  sbox_rom[73]  = 8'h59;  sbox_rom[74]  = 8'h3c;  sbox_rom[75]  = 8'h19;
        sbox_rom[76]  = 8'h e6;  sbox_rom[77]  = 8'h85;  sbox_rom[78]  = 8'h4f;  sbox_rom[79]  = 8'h a8;
        sbox_rom[80]  = 8'h68;  sbox_rom[81]  = 8'h6b;  sbox_rom[82]  = 8'h81;  sbox_rom[83]  = 8'hb2;
        sbox_rom[84]  = 8'h71;  sbox_rom[85]  = 8'h64;  sbox_rom[86]  = 8'hda;  sbox_rom[87]  = 8'h8b;
        sbox_rom[88]  = 8'hf8;  sbox_rom[89]  = 8'h eb;  sbox_rom[90]  = 8'h0f;  sbox_rom[91]  = 8'h4b;
        sbox_rom[92]  = 8'h70;  sbox_rom[93]  = 8'h56;  sbox_rom[94]  = 8'h9d;  sbox_rom[95]  = 8'h35;
        sbox_rom[96]  = 8'h1e;  sbox_rom[97]  = 8'h24;  sbox_rom[98]  = 8'h0e;  sbox_rom[99]  = 8'h5e;
        sbox_rom[100] = 8'h63;  sbox_rom[101] = 8'h58;  sbox_rom[102] = 8'h d1;  sbox_rom[103] = 8'ha2;
        sbox_rom[104] = 8'h25;  sbox_rom[105] = 8'h22;  sbox_rom[106] = 8'h7c;  sbox_rom[107] = 8'h3b;
        sbox_rom[108] = 8'h01;  sbox_rom[109] = 8'h21;  sbox_rom[110] = 8'h78;  sbox_rom[111] = 8'h87;
        sbox_rom[112] = 8'h d4;  sbox_rom[113] = 8'h00;  sbox_rom[114] = 8'h46;  sbox_rom[115] = 8'h57;
        sbox_rom[116] = 8'h9f;  sbox_rom[117] = 8'h d3;  sbox_rom[118] = 8'h27;  sbox_rom[119] = 8'h52;
        sbox_rom[120] = 8'h4c;  sbox_rom[121] = 8'h36;  sbox_rom[122] = 8'h02;  sbox_rom[123] = 8'h e7;
        sbox_rom[124] = 8'ha0;  sbox_rom[125] = 8'h c4;  sbox_rom[126] = 8'h c8;  sbox_rom[127] = 8'h9e;
        sbox_rom[128] = 8'h ea;  sbox_rom[129] = 8'hbf;  sbox_rom[130] = 8'h8a;  sbox_rom[131] = 8'h d2;
        sbox_rom[132] = 8'h40;  sbox_rom[133] = 8'h c7;  sbox_rom[134] = 8'h38;  sbox_rom[135] = 8'hb5;
        sbox_rom[136] = 8'ha3;  sbox_rom[137] = 8'hf7;  sbox_rom[138] = 8'hf2;  sbox_rom[139] = 8'hce;
        sbox_rom[140] = 8'hf9;  sbox_rom[141] = 8'h61;  sbox_rom[142] = 8'h15;  sbox_rom[143] = 8'h a1;
        sbox_rom[144] = 8'h e0;  sbox_rom[145] = 8'h ae;  sbox_rom[146] = 8'h5d;  sbox_rom[147] = 8'h a4;
        sbox_rom[148] = 8'h9b;  sbox_rom[149] = 8'h34;  sbox_rom[150] = 8'h1a;  sbox_rom[151] = 8'h55;
        sbox_rom[152] = 8'h ad;  sbox_rom[153] = 8'h93;  sbox_rom[154] = 8'h32;  sbox_rom[155] = 8'h30;
        sbox_rom[156] = 8'hf5;  sbox_rom[157] = 8'h8c;  sbox_rom[158] = 8'hb1;  sbox_rom[159] = 8'h e3;
        sbox_rom[160] = 8'h1d;  sbox_rom[161] = 8'hf6;  sbox_rom[162] = 8'h e2;  sbox_rom[163] = 8'h2e;
        sbox_rom[164] = 8'h82;  sbox_rom[165] = 8'h66;  sbox_rom[166] = 8'hca;  sbox_rom[167] = 8'h60;
        sbox_rom[168] = 8'h c0;  sbox_rom[169] = 8'h29;  sbox_rom[170] = 8'h23;  sbox_rom[171] = 8'h ab;
        sbox_rom[172] = 8'h0d;  sbox_rom[173] = 8'h53;  sbox_rom[174] = 8'h4e;  sbox_rom[175] = 8'h6f;
        sbox_rom[176] = 8'h d5;  sbox_rom[177] = 8'hdb;  sbox_rom[178] = 8'h37;  sbox_rom[179] = 8'h45;
        sbox_rom[180] = 8'hde;  sbox_rom[181] = 8'hfd;  sbox_rom[182] = 8'h8e;  sbox_rom[183] = 8'h2f;
        sbox_rom[184] = 8'h03;  sbox_rom[185] = 8'hff;  sbox_rom[186] = 8'h6a;  sbox_rom[187] = 8'h72;
        sbox_rom[188] = 8'h6d;  sbox_rom[189] = 8'h6c;  sbox_rom[190] = 8'h5b;  sbox_rom[191] = 8'h51;
        sbox_rom[192] = 8'h8d;  sbox_rom[193] = 8'h1b;  sbox_rom[194] = 8'haf;  sbox_rom[195] = 8'h92;
        sbox_rom[196] = 8'hbb;  sbox_rom[197] = 8'hdd;  sbox_rom[198] = 8'hbc;  sbox_rom[199] = 8'h7f;
        sbox_rom[200] = 8'h11;  sbox_rom[201] = 8'h d9;  sbox_rom[202] = 8'h5c;  sbox_rom[203] = 8'h41;
        sbox_rom[204] = 8'h1f;  sbox_rom[205] = 8'h10;  sbox_rom[206] = 8'h5a;  sbox_rom[207] = 8'h d8;
        sbox_rom[208] = 8'h0a;  sbox_rom[209] = 8'h c1;  sbox_rom[210] = 8'h31;  sbox_rom[211] = 8'h88;
        sbox_rom[212] = 8'h a5;  sbox_rom[213] = 8'hcd;  sbox_rom[214] = 8'h7b;  sbox_rom[215] = 8'hbd;
        sbox_rom[216] = 8'h2d;  sbox_rom[217] = 8'h74;  sbox_rom[218] = 8'h d0;  sbox_rom[219] = 8'h12;
        sbox_rom[220] = 8'hb8;  sbox_rom[221] = 8'h e5;  sbox_rom[222] = 8'hb4;  sbox_rom[223] = 8'hb0;
        sbox_rom[224] = 8'h89;  sbox_rom[225] = 8'h69;  sbox_rom[226] = 8'h97;  sbox_rom[227] = 8'h4a;
        sbox_rom[228] = 8'h0c;  sbox_rom[229] = 8'h96;  sbox_rom[230] = 8'h77;  sbox_rom[231] = 8'h7e;
        sbox_rom[232] = 8'h65;  sbox_rom[233] = 8'h b9;  sbox_rom[234] = 8'hf1;  sbox_rom[235] = 8'h09;
        sbox_rom[236] = 8'h c5;  sbox_rom[237] = 8'h6e;  sbox_rom[238] = 8'h c6;  sbox_rom[239] = 8'h84;
        sbox_rom[240] = 8'h18;  sbox_rom[241] = 8'hf0;  sbox_rom[242] = 8'h7d;  sbox_rom[243] = 8'h ec;
        sbox_rom[244] = 8'h3a;  sbox_rom[245] = 8'h dc;  sbox_rom[246] = 8'h4d;  sbox_rom[247] = 8'h20;
        sbox_rom[248] = 8'h79;  sbox_rom[249] = 8'h ee;  sbox_rom[250] = 8'h5f;  sbox_rom[251] = 8'h3e;
        sbox_rom[252] = 8'h d7;  sbox_rom[253] = 8'h cb;  sbox_rom[254] = 8'h39;  sbox_rom[255] = 8'h48;
    end
    
    always @(posedge clk) begin
        if (en)
            y <= sbox_rom[x];
    end

endmodule

