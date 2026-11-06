"""Independent integer tensor formula; no RTL schedule or child-model imports."""
def quantize(acc, scale, shift, zero):
    magnitude = abs(acc) * scale
    divisor = 1 << shift
    whole, remainder = divmod(magnitude, divisor)
    if 2 * remainder > divisor or (2 * remainder == divisor and whole % 2):
        whole += 1
    rounded = -whole if acc < 0 else whole
    value = rounded + zero
    return max(-128, min(127, value)), int(value < -128 or value > 127), int(remainder != 0)

def infer(image, weights, metadata, x_zero, out_channels):
    height, width = len(image), len(image[0])
    result = [[None for _ in range(2 * width)] for _ in range(2 * height)]
    for y, row in enumerate(image):
        for x, vector in enumerate(row):
            for dy in range(2):
                for dx in range(2):
                    result[2*y+dy][2*x+dx] = [
                        quantize(metadata[r][0] + sum((v-x_zero)*w for v,w in zip(vector,weights[r])),
                                 *metadata[r][1:])
                        for r in [(2*dy+dx)*out_channels+c for c in range(out_channels)]
                    ]
    return [(*entry,x,y,c,int(x==0 and y==0 and c==0),
             int(x==2*width-1 and c==out_channels-1),
             int(x==2*width-1 and y==2*height-1 and c==out_channels-1))
            for y,row in enumerate(result) for x,pixel in enumerate(row) for c,entry in enumerate(pixel)]
