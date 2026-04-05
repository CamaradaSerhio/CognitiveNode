import pmt
import threading
import time
from gnuradio import gr
class blk(gr.basic_block):
  def __init__(self):
   gr.basic_block.__init__(self,
     name="scanner",
     in_sig=None,
     out_sig=None)
   #Input and output message ports
   self.message_port_register_in(pmt.intern("map"))
   self.set_msg_handler(pmt.intern("map"), self.handle_map)
   self.message_port_register_out(pmt.intern("command"))
   #Frequency scanning parameters
   self.freq_start = 2e9
   self.freq_stop = 3e9
   self.freq_step = 1e6
   self.current_freq = self.freq_start
   self.min_active_bins = 2 #if >= that many active bits in one frequency step, then we consider as
BUSY
   #Saving the latest map
   self.lock = threading.Lock()
   self.latest_map = {}
   #Start only once
   self.thread_started = False
   #Log file
   self.log = open("/tmp/spectrum_scan_log.txt", "w")
  def handle_map(self, msg):
   #Convert PMT to Python dictionary
   d = pmt.to_python(msg)
   with self.lock:
     self.latest_map = d
   #Start scanning
   if not self.thread_started:
     self.thread_started = True
     threading.Thread(target=self.scan_loop, daemon=True).start()
  def scan_loop(self):
   while True:
     with self.lock:
      d = self.latest_map
     num_active = len(d)
     status = "BUSY" if num_active >= self.min_active_bins else "FREE"
     log_line = f"{time.time()}: {self.current_freq/1e6:.3f} MHz {status} ({num_active} active bins)"
     print(log_line)
     self.log.write(log_line + "\n")
     self.log.flush()
     if status == "FREE":
      msg = pmt.cons(pmt.intern("freq"), pmt.from_double(self.current_freq))
      self.message_port_pub(pmt.intern("command"), msg)
     # Switch to next frequency
     self.current_freq += self.freq_step
     if self.current_freq > self.freq_stop:
      self.current_freq = self.freq_start
     time.sleep(0.5)
  def stop(self):
   self.log.close()
   return super().stop()
