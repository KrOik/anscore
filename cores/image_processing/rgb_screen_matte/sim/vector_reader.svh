// SPDX-License-Identifier: Apache-2.0
// Shared file reader only; every expected value comes from the independent model.
localparam integer MAX_ROWS=4096;
integer vector_total;
reg [23:0] v_rgb[0:MAX_ROWS-1],v_key[0:MAX_ROWS-1];
reg [18:0] v_inner[0:MAX_ROWS-1],v_outer[0:MAX_ROWS-1];
reg [7:0] v_strength[0:MAX_ROWS-1];
reg v_blue[0:MAX_ROWS-1],v_sof[0:MAX_ROWS-1],v_eol[0:MAX_ROWS-1],v_last[0:MAX_ROWS-1];
reg [15:0] v_x[0:MAX_ROWS-1],v_y[0:MAX_ROWS-1];
reg [31:0] v_tag[0:MAX_ROWS-1],v_user[0:MAX_ROWS-1],v_rgba[0:MAX_ROWS-1];
reg v_error[0:MAX_ROWS-1];
reg [31:0] v_background[0:MAX_ROWS-1],v_over[0:MAX_ROWS-1];
reg [2:0] v_over_error[0:MAX_ROWS-1];
string vector_path;
task load_vectors;
    integer handle,row,fields,character;
    begin
        if(!$value$plusargs("VECTORS=%s",vector_path)) $fatal(1,"missing VECTORS path");
        handle=$fopen(vector_path,"r");
        if(handle==0) $fatal(1,"cannot open vectors");
        fields=$fscanf(handle,"%d",vector_total);
        if(fields!=1 || vector_total<512 || vector_total>MAX_ROWS) $fatal(1,"bad vector count");
        for(row=0;row<vector_total;row=row+1) begin
            fields=$fscanf(handle,"%h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h",
                v_rgb[row],v_key[row],v_inner[row],v_outer[row],v_strength[row],v_blue[row],
                v_x[row],v_y[row],v_tag[row],v_sof[row],v_eol[row],v_last[row],v_user[row],
                v_rgba[row],v_error[row],v_background[row],v_over[row],v_over_error[row]);
            if(fields!=18) $fatal(1,"vector row %0d fields=%0d",row,fields);
        end
        character=$fgetc(handle);
        while(character!=-1) begin
            if(character!=9 && character!=10 && character!=11 && character!=12 &&
               character!=13 && character!=32) $fatal(1,"nonwhite vector tail byte=%0d",character);
            character=$fgetc(handle);
        end
        $fclose(handle);
    end
endtask
