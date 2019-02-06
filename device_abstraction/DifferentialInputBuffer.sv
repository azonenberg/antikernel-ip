`timescale 1ns / 1ps
/***********************************************************************************************************************
*                                                                                                                      *
* ANTIKERNEL v0.1                                                                                                      *
*                                                                                                                      *
* Copyright (c) 2012-2019 Andrew D. Zonenberg                                                                          *
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

/**
	@file
	@author Andrew D. Zonenberg
	@brief Ganged collection of differential input buffers for a parallel input bus
 */
module DifferentialInputBuffer #(
	parameter WIDTH 		= 1,
	parameter IOSTANDARD 	= "LVDS",
	parameter ODT 			= 1,					//enable on-die termination
	parameter OPTIMIZE		= "SPEED"				//"SPEED" or "POWER", not supported in all devices
)(
	input wire[WIDTH-1:0]	pad_in_p,
	input wire[WIDTH-1:0]	pad_in_n,
	output wire[WIDTH-1:0]	fabric_out
);

	////////////////////////////////////////////////////////////////////////////////////////////////
	// The buffer array

	initial begin
		if( (OPTIMIZE == "SPEED") || (OPTIMIZE == "POWER") ) begin
		end

		else begin
			$fatal(0, "Invalid optimization goal (must be SPEED or POWER)");
		end
	end

	genvar g;
	for(g=0; g<WIDTH; g=g+1) begin : ibufs

		IBUFDS #(
			.IOSTANDARD(IOSTANDARD),
			.IBUF_LOW_PWR(OPTIMIZE == "POWER" ? "TRUE" : "FALSE"),
			.DIFF_TERM(ODT ? "TRUE" : "FALSE")
		) ibuf (
			.I(pad_in_p[g]),
			.IB(pad_in_n[g]),
			.O(fabric_out[g])
		);

	end

endmodule
