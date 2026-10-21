import numpy as np

def rne(n,bits):
 q,r=divmod(int(n),1<<bits)
 return q+int(r>(1<<(bits-1)) or (r==(1<<(bits-1)) and q%2))

def weights(mu):
 u=float(mu)
 return np.array([-.5*u+u*u-.5*u**3,1-2.5*u*u+1.5*u**3,
                  .5*u+2*u*u-1.5*u**3,-.5*u*u+.5*u**3])

def floating(samples,delay=0,mu=0):
 if not 0<=delay<=31 or not 0<=mu<=1:raise ValueError('delay/mu')
 return np.convolve(np.asarray(samples,dtype=float),np.r_[np.zeros(delay),weights(mu)])[:len(samples)]

def bitexact(window,u):
 if not 0<=u<=4096:raise ValueError('mu')
 a,b,c,d=map(int,window)
 p=(-a+3*b-3*c+d)*256
 for coefficient in (2*a-5*b+4*c-d,c-a,2*b):p=rne(p*u,12)+coefficient*256
 value=rne(p,9)
 return min(32767,max(-32768,value)),int(not -32768<=value<=32767)

class StreamModel:
 def __init__(self):self.delay=0;self.mu=0;self.history=[]
 def config(self,delay,mu,clear):
  if not 0<=delay<=31 or not 0<=mu<=4096:return False
  self.delay=delay;self.mu=mu
  if clear:self.history=[]
  return True
 def sample(self,x):
  self.history.insert(0,int(x));self.history=self.history[:35]
  window=[self.history[k] if k<len(self.history) else 0 for k in range(self.delay,self.delay+4)]
  return bitexact(window,self.mu)
