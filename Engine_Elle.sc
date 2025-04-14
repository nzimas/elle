Engine_Elle : CroneEngine {
	classvar nvoices = 6;

	var pg;
	var <delaySynthL; // Delay synth for Left channel
	var <delaySynthR; // Delay synth for Right channel
	var <drySynth;    // Synth to pass through dry signal

	var <buffersL;
	var <buffersR;
	var <voices;
	var mixBus; // Bus for voices output, before effects
	var <phases;
	var <levels;

	var <seek_tasks;

	*new { arg context, doneCallback;
		^super.new(context, doneCallback);
	}

	// disk read (Unchanged from original)
	readBuf { arg i, path;
		if(buffersL[i].notNil && buffersR[i].notNil, {
			if(File.exists(path.asString()), {
				var numChannels;
				var newbuf;

				numChannels = SoundFile.use(path.asString(), { |f| f.numChannels });

				// Read left channel (or mono)
				newbuf = Buffer.readChannel(context.server, path, 0, -1, [0], { |b|
					voices[i].set(\buf_l, b);
					buffersL[i].free;
					buffersL[i] = b;
				});

				// Read right channel if stereo, otherwise reuse left buffer
				if(numChannels > 1, {
					newbuf = Buffer.readChannel(context.server, path, 0, -1, [1], { |b|
						voices[i].set(\buf_r, b);
						buffersR[i].free;
						buffersR[i] = b;
					});
				},{
					// If mono, use the same buffer for the right channel input of GrainBuf
					// Need to wait for the first buffer to be confirmed loaded? No, set directly.
					voices[i].set(\buf_r, newbuf); // Use the handle from the first read
					buffersR[i].free; // Free the placeholder buffer
					buffersR[i] = newbuf; // Keep track of the shared buffer
				});
			});
		});
	}


	alloc {
		buffersL = Array.fill(nvoices, { arg i;
			Buffer.alloc(
				context.server,
				context.server.sampleRate * 1 // 1 second placeholder
			);
		});

		buffersR = Array.fill(nvoices, { arg i;
			Buffer.alloc(
				context.server,
				context.server.sampleRate * 1 // 1 second placeholder
			);
		});

		// SynthDef for granular voices (Unchanged from original)
		SynthDef(\synth, {
			arg out, phase_out, level_out,
				buf_l, buf_r,
				gate=0, pos=0, speed=1, jitter=0,
				size=0.1, density=20, pitch=1, pan=0, spread=0, gain=1, envscale=1,
				freeze=0, t_reset_pos=0,

				// per-voice resonant filter
				filterFreq=8000, filterRQ=0.5,

				// PitchShift arguments
				shiftWindow=0.1,
				shiftRatio=1.0,
				shiftPitchDispersion=0.0,
				shiftTimeDispersion=0.0,
				shiftMul=1.0,
				shiftAdd=0.0;

			var grain_trig, jitter_sig, buf_dur, pan_sig;
			var buf_pos, pos_sig, sig_l, sig_r, sig_mix, env, level;

			// Granular triggering
			grain_trig = Impulse.kr(density);
			buf_dur = BufDur.kr(buf_l); // Assuming L/R have same duration

			pan_sig = TRand.kr(
				trig: grain_trig,
				lo: spread.neg,
				hi: spread
			);

			jitter_sig = TRand.kr(
				trig: grain_trig,
				lo: buf_dur.reciprocal.neg * jitter,
				hi: buf_dur.reciprocal * jitter
			);

			// Phase tracking
			buf_pos = Phasor.kr(
				trig: t_reset_pos,
				rate: buf_dur.reciprocal / ControlRate.ir * speed,
				resetPos: pos
			);

			pos_sig = Wrap.kr(Select.kr(freeze, [buf_pos, pos]));

			// Granular voices
			sig_l = GrainBuf.ar(
				1, grain_trig, size, buf_l, pitch, pos_sig + jitter_sig, 2
			);
			sig_r = GrainBuf.ar(
				1, grain_trig, size, buf_r, pitch, pos_sig + jitter_sig, 2
			);

			// Combine L/R with per‐voice panning
			sig_mix = Balance2.ar(sig_l, sig_r, pan + pan_sig);

			// PitchShift inserted immediately after granular voices
			sig_mix = PitchShift.ar(
				sig_mix,
				shiftWindow,
				shiftRatio,
				shiftPitchDispersion,
				shiftTimeDispersion,
				shiftMul,
				shiftAdd
			);

			// Per-voice resonant filter
			sig_mix = RLPF.ar(sig_mix, filterFreq, filterRQ);

			// Per-voice envelope
			env = EnvGen.kr(Env.asr(1, 1, 1), gate: gate, timeScale: envscale);
			level = env;

			// Output stereo signal to the mix bus
			Out.ar(out, sig_mix * level * gain);
			Out.kr(phase_out, pos_sig);
			Out.kr(level_out, level);
		}).add;

		// --- NEW: SynthDef for dry signal pass-through ---
		SynthDef(\thru, {
			arg in, out;
			var sig = In.ar(in, 2); // Read stereo signal from input bus
			Out.ar(out, sig);       // Write stereo signal to output bus
		}).add;

		// --- MODIFIED: Mono Delay SynthDef with panning ---
		SynthDef(\monoDelay, {
			arg in, out, pan = 0, // Added pan argument
				delayTime=0.5, feedback=0.5, mix=0.5, maxDelay=2.0,

				// Decimator parameters
				deciRate=44100.0, deciBits=24, deciMul=1.0, deciAdd=0.0;

			var dry, fb, delayed, wet, outSig;

			// read the dry signal from the *mono* input bus
			dry = In.ar(in, 1); // Changed to 1 channel

			// read feedback from the local loop (mono)
			fb = LocalIn.ar(1); // Changed to 1 channel

			// pass sum of dry + feedback into delay (mono)
			delayed = DelayL.ar(dry + (fb * feedback), maxDelay, delayTime);

			// decimate inside the feedback loop
			delayed = Decimator.ar(
				delayed,
				rate: deciRate,
				bits: deciBits,
				mul: deciMul,
				add: deciAdd
			);

			// store delayed (bit-reduced) signal back into local loop (mono)
			LocalOut.ar(delayed); // Changed to 1 channel output

			// final wet/dry mix (mono signal)
			wet = delayed;
			outSig = (dry * (1 - mix)) + (wet * mix);

			// Pan the final mono output signal and send to stereo output bus
			Out.ar(out, Pan2.ar(outSig, pan)); // Use Pan2 for output
		}).add;

		context.server.sync;

		// mix bus for all synth outputs (stereo)
		mixBus = Bus.audio(context.server, 2);

		// --- NEW: Instantiate dry signal pass-through ---
		// Placed at the tail of the effect group to run after voice group output
		drySynth = Synth.tail(context.xg, \thru, [
			\in, mixBus.index,
			\out, context.out_b.index // Main output
		]);

		// --- NEW: Instantiate Left Delay ---
		// Reads Left channel from mixBus (index), outputs panned left
		delaySynthL = Synth.tail(context.xg, \monoDelay, [
			\in, mixBus.index,       // Reads Left channel (bus index)
			\out, context.out_b.index, // Main output start index
			\pan, -1                 // Pan hard left
			// Add initial parameter settings if needed, e.g., \delayTime, 0.3
		]);

		// --- NEW: Instantiate Right Delay ---
		// Reads Right channel from mixBus (index + 1), outputs panned right
		delaySynthR = Synth.tail(context.xg, \monoDelay, [
			\in, mixBus.index + 1,   // Reads Right channel (bus index + 1)
			\out, context.out_b.index, // Main output start index
			\pan, 1                  // Pan hard right
			// Add initial parameter settings if needed, e.g., \delayTime, 0.4
		]);

		// Control buses for phase and level (Unchanged)
		phases = Array.fill(nvoices, { arg i; Bus.control(context.server); });
		levels = Array.fill(nvoices, { arg i; Bus.control(context.server); });

		// Group for synth voices (Unchanged)
		pg = ParGroup.head(context.xg); // Voices run first

		// Instantiate granular voices (Unchanged, output to mixBus)
		voices = Array.fill(nvoices, { arg i;
			Synth.new(\synth, [
				\out, mixBus.index, // Output to the stereo mixBus
				\phase_out, phases[i].index,
				\level_out, levels[i].index,
				\buf_l, buffersL[i],
				\buf_r, buffersR[i],
				\filterFreq, 8000,
				\filterRQ, 0.5
				// Initial pitch shift etc. can be set here too
			], target: pg); // Add voices to their own group
		});

		context.server.sync;

		// --- COMMAND HANDLERS ---

		// File read command (Unchanged)
		this.addCommand("read", "is", { arg msg;
			this.readBuf(msg[1] - 1, msg[2]);
		});

		// Seek command (Unchanged logic, ensure seek_tasks is initialized)
		this.addCommand("seek", "if", { arg msg;
			var voice = msg[1] - 1;
			var lvl, pos;
			var seek_rate = 1 / 750; // ~750 Hz update rate for smooth seek

			seek_tasks[voice].stop; // Stop existing seek task for this voice

			lvl = levels[voice].getSynchronous(); // Check current level (optional use)

			// Simplified instant seek - advanced routine commented out in original
			pos = msg[2];
			voices[voice].set(\pos, pos); // Set the new position directly
			voices[voice].set(\t_reset_pos, 1); // Trigger phasor reset
			voices[voice].set(\freeze, 0); // Ensure playback is active

		});

		// Voice parameter commands (Unchanged)
		this.addCommand("gate", "ii", { arg msg; voices[msg[1]-1].set(\gate, msg[2]); });
		this.addCommand("speed", "if", { arg msg; voices[msg[1]-1].set(\speed, msg[2]); });
		this.addCommand("jitter", "if", { arg msg; voices[msg[1]-1].set(\jitter, msg[2]); });
		this.addCommand("size", "if", { arg msg; voices[msg[1]-1].set(\size, msg[2]); });
		this.addCommand("density", "if", { arg msg; voices[msg[1]-1].set(\density, msg[2]); });
		this.addCommand("pitch", "if", { arg msg; voices[msg[1]-1].set(\pitch, msg[2]); });
		this.addCommand("pan", "if", { arg msg; voices[msg[1]-1].set(\pan, msg[2]); });
		this.addCommand("spread", "if", { arg msg; voices[msg[1]-1].set(\spread, msg[2]); });
		this.addCommand("volume", "if", { arg msg; voices[msg[1]-1].set(\gain, msg[2]); });
		this.addCommand("envscale", "if", { arg msg; voices[msg[1]-1].set(\envscale, msg[2]); });
		this.addCommand("filterCutoff", "if", { arg msg; voices[msg[1]-1].set(\filterFreq, msg[2]); });
		this.addCommand("filterRQ", "if", { arg msg; voices[msg[1]-1].set(\filterRQ, msg[2]); });
		this.addCommand("ps_windowSize", "if", { arg msg; voices[msg[1]-1].set(\shiftWindow, msg[2]); });
		this.addCommand("ps_pitchRatio", "if", { arg msg; voices[msg[1]-1].set(\shiftRatio, msg[2]); });
		this.addCommand("ps_pitchDispersion", "if", { arg msg; voices[msg[1]-1].set(\shiftPitchDispersion, msg[2]); });
		this.addCommand("ps_timeDispersion", "if", { arg msg; voices[msg[1]-1].set(\shiftTimeDispersion, msg[2]); });
		this.addCommand("ps_mul", "if", { arg msg; voices[msg[1]-1].set(\shiftMul, msg[2]); });
		this.addCommand("ps_add", "if", { arg msg; voices[msg[1]-1].set(\shiftAdd, msg[2]); });


		// --- MODIFIED/NEW: Delay parameter commands ---

		// Left Delay Commands
		this.addCommand("delay_time_l", "f", { arg msg; delaySynthL.set(\delayTime, msg[1]); });
		this.addCommand("delay_feedback_l", "f", { arg msg; delaySynthL.set(\feedback, msg[1]); });
		this.addCommand("delay_mix_l", "f", { arg msg; delaySynthL.set(\mix, msg[1]); });
		this.addCommand("decimator_rate_l", "f", { arg msg; delaySynthL.set(\deciRate, msg[1]); });
		this.addCommand("decimator_bits_l", "f", { arg msg; delaySynthL.set(\deciBits, msg[1]); });
		this.addCommand("decimator_mul_l", "f", { arg msg; delaySynthL.set(\deciMul, msg[1]); });
		this.addCommand("decimator_add_l", "f", { arg msg; delaySynthL.set(\deciAdd, msg[1]); });

		// Right Delay Commands (New)
		this.addCommand("delay_time_r", "f", { arg msg; delaySynthR.set(\delayTime, msg[1]); });
		this.addCommand("delay_feedback_r", "f", { arg msg; delaySynthR.set(\feedback, msg[1]); });
		this.addCommand("delay_mix_r", "f", { arg msg; delaySynthR.set(\mix, msg[1]); });
		this.addCommand("decimator_rate_r", "f", { arg msg; delaySynthR.set(\deciRate, msg[1]); });
		this.addCommand("decimator_bits_r", "f", { arg msg; delaySynthR.set(\deciBits, msg[1]); });
		this.addCommand("decimator_mul_r", "f", { arg msg; delaySynthR.set(\deciMul, msg[1]); });
		this.addCommand("decimator_add_r", "f", { arg msg; delaySynthR.set(\deciAdd, msg[1]); });


		// Polling setup (Unchanged)
		nvoices.do({ arg i;
			this.addPoll(("phase_" ++ (i+1)).asSymbol, { phases[i].getSynchronous });
			this.addPoll(("level_" ++ (i+1)).asSymbol, { levels[i].getSynchronous });
		});

		// Initialize seek tasks (Unchanged)
		seek_tasks = Array.fill(nvoices, { Routine {} });
	}

	free {
		// Free granular voices
		voices.do({ arg voice; voice.free; });

		// Free control buses
		phases.do({ arg bus; bus.free; });
		levels.do({ arg bus; bus.free; });

		// Free audio buffers
		buffersL.do({ arg b; b.free; });
		// Note: buffersR might contain references to buffersL if mono files were loaded
		// SuperCollider's Buffer.free handles freeing only once if referenced multiple times.
		buffersR.do({ arg b; b.free; });

		delaySynthL.free;
		delaySynthR.free;
		drySynth.free;
		mixBus.free;

		// Stop any running seek tasks
		seek_tasks.do(_.stop);
	}
}
