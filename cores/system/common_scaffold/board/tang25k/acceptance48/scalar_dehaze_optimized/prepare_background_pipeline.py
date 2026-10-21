from pathlib import Path
HERE=Path(__file__).resolve().parent
source=(HERE/'background_model_harness_v3/source/cip_image_background_model.v').read_text()
source=source.replace('OUTPUT_HOLD=3,RESPONSE=4;', 'OUTPUT_HOLD=3,RESPONSE=4,MODEL_DELTA=5,MODEL_SHIFT=6;')
source=source.replace('wire signed [MODEL_W+1:0] updated=', 'reg signed [MODEL_W+1:0] delta_q,shifted_q;\nreg [DATA_W-1:0] difference_q;\nreg foreground_q;\nwire signed [MODEL_W+1:0] updated=')
source=source.replace('(delta >>> update_shift)', 'shifted_q')
source=source.replace('((freeze_foreground && foreground)?', '((freeze_foreground && foreground_q)?')
source=source.replace('state<=IDLE;mode<=0;', 'delta_q<=0;shifted_q<=0;difference_q<=0;foreground_q<=0;\n        state<=IDLE;mode<=0;')
source=source.replace('pending_data<=s_data;state<=MODEL_UPDATE;', 'pending_data<=s_data;state<=MODEL_DELTA;')
source=source.replace('        MODEL_UPDATE:begin', '''        MODEL_DELTA:begin
            delta_q<=delta;difference_q<=difference;foreground_q<=foreground;
            state<=MODEL_SHIFT;
        end
        MODEL_SHIFT:begin
            shifted_q<=delta_q >>> update_shift;
            state<=MODEL_UPDATE;
        end
        MODEL_UPDATE:begin''')
source=source.replace('packet<={{8{1\'b0}},difference};', 'packet<={{8{1\'b0}},difference_q};')
source=source.replace('2:packet<=foreground?', '2:packet<=foreground_q?')
(HERE/'cip_image_background_model.v').write_text(source)
