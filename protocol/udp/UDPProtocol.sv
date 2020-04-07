`timescale 1ns / 1ps
`default_nettype none
/***********************************************************************************************************************
*                                                                                                                      *
* ANTIKERNEL v0.1                                                                                                      *
*                                                                                                                      *
* Copyright (c) 2012-2020 Andrew D. Zonenberg                                                                          *
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

`include "IPv4Bus.svh"
`include "UDPv4Bus.svh"

module UDPProtocol(

	//Clocks
	input wire			clk,

	//Incoming data bus from IP stack
	//TODO: make this parameterizable for IPv4/IPv6, for now we only do v4
	input wire IPv4RxBus	rx_l3_bus,
	output IPv4TxBus		tx_l3_bus	=	{$bits(IPv4TxBus){1'b0}},

	//Outbound bus to applications
	output UDPv4RxBus		rx_l4_bus	=	{$bits(UDPv4RxBus){1'b0}},
	input UDPv4TxBus		tx_l4_bus
);

	////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	// RX checksum verification

	wire[15:0]	rx_checksum_expected;

	InternetChecksum32bit rx_csum(
		.clk(clk),
		.load(rx_l3_bus.start),
		.reset(1'b0),
		.process(rx_l3_bus.data_valid),
		.din(rx_l3_bus.data_valid ? rx_l3_bus.data : rx_l3_bus.pseudo_header_csum),
		.sumout(),
		.csumout(rx_checksum_expected)
	);

	////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	// RX datapath

	enum logic[3:0]
	{
		RX_STATE_IDLE		= 4'h0,
		RX_STATE_HEADER_1	= 4'h1,
		RX_STATE_HEADER_2	= 4'h2,
		RX_STATE_BODY		= 4'h3,
		RX_STATE_PADDING	= 4'h4,
		RX_STATE_CHECKSUM	= 4'h5
	} rx_state = RX_STATE_IDLE;

	reg[15:0]	rx_l4_bytes_left	= 0;

	always @(posedge clk) begin

		//Forward flags from IP stack
		rx_l4_bus.drop			<= rx_l3_bus.drop;

		//Clear flags
		rx_l4_bus.start			<= 0;
		rx_l4_bus.data_valid	<= 0;
		rx_l4_bus.bytes_valid	<= 0;
		rx_l4_bus.commit		<= 0;

		case(rx_state)

			//Start when we get a new packet
			RX_STATE_IDLE: begin

				//Drop anything too small for UDP headers, or not UDP
				if(rx_l3_bus.start && (rx_l3_bus.payload_len >= 8) && rx_l3_bus.protocol_is_udp )
					rx_state			<= RX_STATE_HEADER_1;

			end	//end RX_STATE_IDLE

			//Port header
			RX_STATE_HEADER_1: begin
				if(rx_l3_bus.data_valid) begin

					//Drop truncated packets
					if(rx_l3_bus.bytes_valid != 4)
						rx_state	<= RX_STATE_IDLE;

					else begin
						rx_l4_bus.src_port	<= rx_l3_bus.data[31:16];
						rx_l4_bus.dst_port	<= rx_l3_bus.data[15:0];
						rx_state			<= RX_STATE_HEADER_2;
					end

				end
			end	//end RX_STATE_HEADER_1

			RX_STATE_HEADER_2: begin

				if(rx_l3_bus.data_valid) begin

					//Drop truncated packets
					if(rx_l3_bus.bytes_valid != 4)
						rx_state	<= RX_STATE_IDLE;

					//Drop anything with an invalid size
					else if(rx_l3_bus.data[31:16] < 8)
						rx_state	<= RX_STATE_IDLE;

					//Only send start once all the headers are here and double-checked
					else begin
						rx_l4_bus.start			<= 1;
						//rx_checksum			<= rx_l3_bus.data[15:0];
						rx_l4_bus.payload_len	<= rx_l3_bus.data[31:16] - 16'h8;
						rx_l4_bytes_left		<= rx_l3_bus.data[31:16] - 16'h8;	//start off at payload length
						rx_l4_bus.src_ip		<= rx_l3_bus.src_ip;

						rx_state				<= RX_STATE_BODY;
					end

				end

			end	//end RX_STATE_HEADER_2

			RX_STATE_BODY: begin

				//Forward data
				if(rx_l3_bus.data_valid) begin

					rx_l4_bus.data_valid		<= 1;
					rx_l4_bus.data				<= rx_l3_bus.data;
					rx_l4_bus.bytes_valid		<= rx_l3_bus.bytes_valid;

					//Data plus padding at layer 3? Set the valid flag to exclude the padding
					if(rx_l4_bytes_left < rx_l3_bus.bytes_valid) begin
						rx_l4_bus.bytes_valid	<= rx_l4_bytes_left;
						rx_state				<= RX_STATE_PADDING;
					end

					//Update byte counter
					rx_l4_bytes_left			<= rx_l4_bytes_left - rx_l3_bus.data_valid;
				end

				//Verify checksum etc
				if(rx_l3_bus.commit)
					rx_state				<= RX_STATE_CHECKSUM;

			end	//end RX_STATE_BODY

			RX_STATE_PADDING: begin

				//Verify checksum etc
				if(rx_l3_bus.commit)
					rx_state				<= RX_STATE_CHECKSUM;

			end	//end RX_STATE_PADDING

			RX_STATE_CHECKSUM: begin
				if(rx_checksum_expected == 16'h0000) begin
					rx_l4_bus.commit	<= 1;
					rx_state			<= RX_STATE_IDLE;
				end
				else begin
					rx_l4_bus.drop		<= 1;
					rx_state			<= RX_STATE_IDLE;
				end
			end	//end RX_STATE_CHECKSUM

		endcase

		//If we get a drop request from the IP stack, abort everything
		if(rx_l3_bus.drop) begin

			//Forward the drop request if we sent the start request to the application layer.
			//If they never saw the start, they don't need to see the drop.
			if(rx_state > RX_STATE_HEADER_2)
				rx_l4_bus.drop	<= 1;

			rx_state	<= RX_STATE_IDLE;
		end

	end

	////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
	// TX datapath

	//For now, send packets with no che=cksum (rely on the 802.3 FCS)

	logic[2:0]	tx_valid_ff		= 0;
	logic[2:0]	tx_valid_ff2	= 0;

	logic[31:0]	tx_data_ff		= 0;
	logic[31:0]	tx_data_ff2		= 0;

	logic		committed		= 0;

	enum logic[3:0]
	{
		TX_STATE_IDLE			= 4'h0,
		TX_STATE_HEADER_0		= 4'h1,
		TX_STATE_HEADER_1		= 4'h2,
		TX_STATE_BODY			= 4'h3,
		TX_STATE_COMMIT			= 4'h4
	} tx_state = TX_STATE_IDLE;

	always_ff @(posedge clk) begin

		tx_l3_bus.start			<= 0;
		tx_l3_bus.commit		<= 0;
		tx_l3_bus.drop			<= 0;
		tx_l3_bus.data_valid	<= 0;

		//Tiny FIFO of incoming data
		tx_data_ff				<= tx_l4_bus.data;
		tx_data_ff2				<= tx_data_ff;
		tx_valid_ff				<= tx_l4_bus.data_valid ? tx_l4_bus.bytes_valid : 3'b0;
		tx_valid_ff2			<= tx_valid_ff;

		if(tx_l4_bus.commit)
			committed			<= 1;

		case(tx_state)

			TX_STATE_IDLE: begin
				committed					<= 0;

				if(tx_l4_bus.start) begin
					tx_l3_bus.start			<= 1;
					tx_l3_bus.dst_ip		<= tx_l4_bus.dst_ip;
					tx_l3_bus.payload_len	<= tx_l4_bus.payload_len + 4'd8;
					tx_l3_bus.protocol		<= IP_PROTO_UDP;
					tx_state				<= TX_STATE_HEADER_0;
				end
			end	//end TX_STATE_IDLE

			//Port header
			TX_STATE_HEADER_0: begin
				tx_l3_bus.data_valid		<= 1;
				tx_l3_bus.bytes_valid		<= 4;
				tx_l3_bus.data				<= { tx_l4_bus.src_port, tx_l4_bus.dst_port };
				tx_state					<= TX_STATE_HEADER_1;
			end	//end TX_STATE_HEADER_0

			//Checksum/length header
			TX_STATE_HEADER_1: begin
				tx_l3_bus.data_valid		<= 1;
				tx_l3_bus.bytes_valid		<= 4;
				tx_l3_bus.data				<= { tx_l3_bus.payload_len, 16'h0 };
				tx_state					<= TX_STATE_BODY;
			end //end TX_STATE_HEADER_1

			//Message content
			TX_STATE_BODY: begin
				tx_l3_bus.data_valid		<= 1;
				tx_l3_bus.bytes_valid		<= tx_valid_ff2;
				tx_l3_bus.data				<= tx_data_ff2;

				if(tx_valid_ff == 0)
					tx_state				<= TX_STATE_COMMIT;

			end //end TX_STATE_BODY

			TX_STATE_COMMIT: begin
				if(committed || tx_l4_bus.commit) begin
					tx_l3_bus.commit		<= 1;
					tx_state				<= TX_STATE_IDLE;
				end
			end	//end TX_STATE_COMMIT

		endcase

		//If we get a drop request, drop everything
		if(tx_l4_bus.drop) begin
			tx_state		<= TX_STATE_IDLE;
			tx_l3_bus.drop	<= 1;
		end

	end

endmodule
