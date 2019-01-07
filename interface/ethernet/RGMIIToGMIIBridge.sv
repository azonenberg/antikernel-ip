`timescale 1ns / 1ps
/***********************************************************************************************************************
*                                                                                                                      *
* ANTIKERNEL v0.1                                                                                                      *
*                                                                                                                      *
* Copyright (c) 2012-2018 Andrew D. Zonenberg                                                                          *
* All rights reserved.                                                                                                 *
*                                                                                                                      *
* Redistribution and use in source and binary forms, with or without modification, are permitted provided that the     *
* following conditions are met:                                                                                        *
*                                                                                                                      *
*    * Redistributions of source code must retain the above copyright notice, this list of conditions, and the         *
*      following disclaimer.                                                                                           *
*                                                                                                                      *
*    * Redistributions in binary form must reproduce the above copyright notice, this list of conditions and the       *
*      following disclaimer in the documentation and/or other materials provided with the distribution.                *
*                                                                                                                      *
*    * Neither the name of the author nor the names of any contributors may be used to endorse or promote products     *
*      derived from this software without specific prior written permission.                                           *
*                                                                                                                      *
* THIS SOFTWARE IS PROVIDED BY THE AUTHORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED   *
* TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL *
* THE AUTHORS BE HELD LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES        *
* (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR       *
* BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT *
* (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE       *
* POSSIBILITY OF SUCH DAMAGE.                                                                                          *
*                                                                                                                      *
***********************************************************************************************************************/

`include "GmiiBus.svh"

/**
	@file
	@author Andrew D. Zonenberg
	@brief GMII to [R]GMII converter
 */
module RGMIIToGMIIBridge #(
	parameter PHY_INTERNAL_DELAY = 0	//TODO: debug KSZ9031 RGMII 2.0 internal delay
)(

	//RGMII signals to off-chip device
	input wire			rgmii_rxc,
	input wire[3:0]		rgmii_rxd,
	input wire			rgmii_rx_ctl,

	output wire			rgmii_txc,
	output wire[3:0]	rgmii_txd,
	output wire			rgmii_tx_ctl,

	//GMII signals to MAC
	output wire			gmii_rxc,
	output GmiiBus		gmii_rx_bus = {1'b0, 1'b0, 1'b0, 8'b0},

	input wire			gmii_txc,
	input wire			gmii_txc_90,
	input wire GmiiBus	gmii_tx_bus,

	//In-band status (if supported by the PHY)
	output logic		link_up		= 0
	);

	////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	// RX side

	typedef enum logic[1:0]
	{
		LINK_SPEED_1000M = 2,
		LINK_SPEED_100M = 1,
		LINK_SPEED_10M = 0
	} lspeed_t;

	lspeed_t link_speed;

	wire	gmii_rxc_raw;
	generate
		if(PHY_INTERNAL_DELAY) begin
			assign gmii_rxc_raw = rgmii_rxc;
		end
		else begin
			//Delay the GMII clock to add additional skew as required by RGMII
			//UI is 4000 ps (250 MT/s).
			//Skew at the sender is +/- 500 ps so our valid eye ignoring rise time is from +500 to +3500 ps
			//We need at least 10 ps setup and 340ps hold for Kintex-7, sampling eye is now now +510 to +3160 ps
			//Assuming equal rise/fall time we want to center in this window so use phase offset of 1835 ps.
			//We want the clock moved forward by +1835 ps, which is the same as moving it back by (8000 - 1835) = 2165 ps and
			//inverting it.
			//Rather than inverting the clock, we instead just switch the phases off the DDR buffers.
			IODelayBlock #(
				.WIDTH(1),
				.INPUT_DELAY(2165),
				.OUTPUT_DELAY(0),
				.DIRECTION("IN"),
				.IS_CLOCK(1)
			) rgmii_rxc_idelay (
				.i_pad(rgmii_rxc),
				.i_fabric(gmii_rxc_raw),
				.i_fabric_serdes(),
				.o_pad(),								//not using output datapath
				.o_fabric(1'h0),
				.input_en(1'b1)
			);
		end

		ClockBuffer #(
			.CE("NO"),
			.TYPE("GLOBAL")
		) rxc_buf (
			.clkin(gmii_rxc_raw),
			.ce(1'b1),
			.clkout(gmii_rxc)
		);

		wire[7:0]	gmii_rx_data_parallel;
		wire[1:0]	gmii_rxc_parallel;
		logic[7:0]	gmii_rx_data_parallel_ff	= 0;
		logic[1:0]	gmii_rxc_parallel_ff		= 0;

		wire[7:0]	rx_parallel_data;

		//Convert DDR to SDR signals
		if(PHY_INTERNAL_DELAY) begin
			DDRInputBuffer #(.WIDTH(4)) rgmii_rxd_iddr2(
				.clk_p(gmii_rxc),
				.clk_n(~gmii_rxc),
				.din(rgmii_rxd),
				.dout0(gmii_rx_data_parallel[3:0]),
				.dout1(gmii_rx_data_parallel[7:4])
				);
			DDRInputBuffer #(.WIDTH(1)) rgmii_rxe_iddr2(
				.clk_p(gmii_rxc),
				.clk_n(~gmii_rxc),
				.din(rgmii_rx_ctl),
				.dout0(gmii_rxc_parallel[0]),
				.dout1(gmii_rxc_parallel[1])
				);

			assign rx_parallel_data	= gmii_rx_data_parallel;
		end
		else begin
			DDRInputBuffer #(.WIDTH(4)) rgmii_rxd_iddr2(
				.clk_p(gmii_rxc),
				.clk_n(~gmii_rxc),
				.din(rgmii_rxd),
				.dout0(gmii_rx_data_parallel[7:4]),
				.dout1(gmii_rx_data_parallel[3:0])
				);
			DDRInputBuffer #(.WIDTH(1)) rgmii_rxe_iddr2(
				.clk_p(gmii_rxc),
				.clk_n(~gmii_rxc),
				.din(rgmii_rx_ctl),
				.dout0(gmii_rxc_parallel[1]),
				.dout1(gmii_rxc_parallel[0])
				);

			//Register the signals by one cycle so we can compensate for the clock inversion
			always_ff @(posedge gmii_rxc) begin
				gmii_rx_data_parallel_ff	<= gmii_rx_data_parallel;
				gmii_rxc_parallel_ff		<= gmii_rxc_parallel;
			end

			//Shuffle the nibbles data back to where they should be.
			assign rx_parallel_data	= { gmii_rx_data_parallel[7:4], gmii_rx_data_parallel_ff[3:0] };
		end

		//10/100 un-DDR-ing
		logic		gmii_rx_bus_en_ff	= 0;
		logic		dvalid_raw			= 0;
		logic[31:0]	rx_parallel_data_ff	= 0;
		always_ff @(posedge gmii_rxc) begin
			gmii_rx_bus_en_ff	<= gmii_rx_bus.en;
			rx_parallel_data_ff	<= rx_parallel_data;

			//Sync on start of packet
			if(gmii_rx_bus.en && !gmii_rx_bus_en_ff)
				dvalid_raw		<= 1;

			//Toggle the rest of the time
			else
				dvalid_raw		<= !dvalid_raw;

		end

		always_comb begin
			gmii_rx_bus.data	<= rx_parallel_data;

			if(link_speed == LINK_SPEED_1000M)
				gmii_rx_bus.dvalid	<= 1;

			//special lock for start of packet
			else if(gmii_rx_bus.en && !gmii_rx_bus_en_ff)
				gmii_rx_bus.dvalid	<= 0;

			else if(dvalid_raw) begin
				gmii_rx_bus.data	<= rx_parallel_data_ff;
				gmii_rx_bus.dvalid	<= 1;
			end

			else
				gmii_rx_bus.dvalid	<= 0;


		end

		//rx_er flag is encoded specially to reduce transitions (see RGMII spec section 3.4)
		assign gmii_rx_bus.en = gmii_rxc_parallel_ff[0];
		wire gmii_rx_er_int = gmii_rxc_parallel_ff[0] ^ gmii_rxc_parallel_ff[1];

		assign gmii_rx_bus.er = gmii_rx_er_int && gmii_rx_bus.en;

		/*
			If gmii_rx_er_int is set without gmii_rx_bus.en, that's a special symbol of some sort
			For now, we just ignore them
			0xFF = carrier sense (not meaningful in full duplex)
		 */

	endgenerate

	////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	// TX side

	DDROutputBuffer #
	(
		.WIDTH(1)
	) txc_output
	(
		.clk_p(gmii_txc_90),
		.clk_n(~gmii_txc_90),
		.dout(rgmii_txc),
		.din0(1'b1),
		.din1(1'b0)
	);

	DDROutputBuffer #(.WIDTH(4)) rgmii_txd_oddr2(
		.clk_p(gmii_txc),
		.clk_n(~gmii_txc),
		.dout(rgmii_txd),
		.din0(gmii_tx_bus.data[3:0]),
		.din1(gmii_tx_bus.data[7:4])
		);

	DDROutputBuffer #(.WIDTH(1)) rgmii_txe_oddr2(
		.clk_p(gmii_txc),
		.clk_n(~gmii_txc),
		.dout(rgmii_tx_ctl),
		.din0(gmii_tx_bus.en),
		.din1(gmii_tx_bus.en ^ gmii_tx_bus.er)
		);

	////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	// Decode in-band link state

	always_ff @(posedge gmii_rxc) begin
		if(!gmii_rx_bus.en && !gmii_rx_er_int) begin

			//Inter-frame gap
			link_up		<= gmii_rx_bus.data[0];
			link_speed	<= lspeed_t'(gmii_rx_bus.data[2:1]);

		end
	end

endmodule
